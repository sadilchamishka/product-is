#!/usr/bin/env bash
#
# Runs the backend integration suite as several concurrent shards on one machine.
#
# The GitHub "Integration Test Runner" workflow already splits this suite four ways and runs each shard in its own
# job against its own server. That split is reused here verbatim, but the shards run as parallel processes on a
# single machine instead, which is what a sequential Jenkins run needs.
#
# Each shard gets its own git worktree, its own port offset, and therefore its own IS server, LDAP server, Tomcat
# and SMTP server. The product is built once and every shard runs against the same distribution zip, which is the
# one place this is cheaper than the GitHub workflow: there, all four jobs rebuild it.
#
# Usage:   .github/scripts/run-parallel-integration-tests.sh
# Tuning:  SHARDS=2 ... to use fewer shards; SKIP_BUILD=1 to reuse an existing distribution.
#
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

SHARDS=${SHARDS:-4}
BASE_OFFSET=${BASE_OFFSET:-410}
# Each shard's federation tests start a secondary server at offset+1, so shards must be spaced by more than one.
OFFSET_STEP=${OFFSET_STEP:-10}
WORKDIR=${WORKDIR:-$ROOT/target/parallel-shards}
TEST_MODULE=modules/integration/tests-integration/tests-backend

# The four-way split, copied from .github/workflows/integration-test-runner.yml.
SHARD_1="is-tests-default-configuration,is-test-rest-api,is-test-webhooks,is-tests-scim2,is-test-adaptive-authentication"
SHARD_2="is-test-adaptive-authentication-nashorn,is-test-adaptive-authentication-nashorn-with-restart,is-tests-default-configuration-ldap,is-tests-uuid-user-store,is-tests-federation,is-tests-federation-restart"
SHARD_3="is-tests-oauth-client-secrets,is-tests-jdbc-userstore,is-tests-read-only-userstore,is-tests-oauth-jwt-token-gen-enabled,is-tests-email-username,is-tests-saml-query-profile,is-tests-default-encryption,is-test-session-mgt,is-tests-password-update-api"
SHARD_4="is-tests-with-individual-configuration-changes"

# Every <test> block in testng.xml. Blocks not selected for a shard are disabled in that shard's copy.
ALL_TESTS=(
    is-tests-default-configuration is-test-rest-api is-tests-oauth-client-secrets is-test-webhooks
    is-tests-scim2 is-test-adaptive-authentication is-test-adaptive-authentication-nashorn
    is-test-adaptive-authentication-nashorn-with-restart is-tests-default-configuration-ldap
    is-tests-uuid-user-store is-tests-federation is-tests-federation-restart is-tests-jdbc-userstore
    is-tests-read-only-userstore is-tests-oauth-jwt-token-gen-enabled is-tests-email-username
    is-tests-with-individual-configuration-changes is-tests-saml-query-profile is-tests-default-encryption
    is-test-session-mgt is-tests-password-update-api
)

log() { echo "[$(date +%H:%M:%S)] $*"; }

# --------------------------------------------------------------------------------------------------------------
# 1. Build the product once. Every shard runs against this same zip.
# --------------------------------------------------------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
    log "Building the product once (all shards share the result)..."
    mvn clean install -Dmaven.test.skip=true -Dmaven.javadoc.skip=true --batch-mode > "$ROOT/target-build.log" 2>&1 || {
        log "Build failed. See target-build.log"; exit 1;
    }
fi

CARBON_ZIP=$(ls "$ROOT"/modules/distribution/target/wso2is-*.zip 2>/dev/null | grep -v -- '-src' | head -1)
[ -n "$CARBON_ZIP" ] || { log "No distribution zip found. Run without SKIP_BUILD=1."; exit 1; }
log "Using distribution: $CARBON_ZIP"

# --------------------------------------------------------------------------------------------------------------
# 2. Prepare one worktree per shard, each pinned to its own port offset.
# --------------------------------------------------------------------------------------------------------------
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

prepare_shard() {
    local i=$1 offset=$2 dir=$3 enabled=$4
    git worktree add --detach -f "$dir" HEAD > /dev/null 2>&1

    local automation="$dir/$TEST_MODULE/src/test/resources/automation.xml"
    local testng="$dir/$TEST_MODULE/src/test/resources/testng.xml"

    # Port offset used by the framework when it starts the server for this shard.
    sed -i.bak "s|<parameter name=\"-DportOffset\" value=\"[0-9]*\"|<parameter name=\"-DportOffset\" value=\"$offset\"|" "$automation"

    # The three declared instances must match that offset: identity001 is the shard's own server, identity002 and
    # identity003 are the secondary servers some suites start at offset+1 and offset+2.
    python3 - "$automation" "$offset" <<'PY'
import re, sys
path, offset = sys.argv[1], int(sys.argv[2])
s = open(path).read()
for n in (1, 2, 3):
    off = offset + n - 1
    s = re.sub(
        r'(<instance name="identity%03d".*?<ports>.*?<port type="http">)\d+(</port>\s*<port type="https">)\d+(</port>)' % n,
        lambda m: f'{m.group(1)}{9763 + off}{m.group(2)}{9443 + off}{m.group(3)}',
        s, flags=re.S)
# The test SMTP server moves with the shard too.
s = re.sub(r'(<port>)3025(</port>)', lambda m: f'{m.group(1)}{3025 + offset - 410}{m.group(2)}', s)
open(path, 'w').write(s)
PY

    # Disable every <test> block this shard is not responsible for.
    IFS=',' read -ra ON <<< "$enabled"
    for t in "${ALL_TESTS[@]}"; do
        if [[ ! " ${ON[*]} " =~ " ${t} " ]]; then
            sed -i.bak "s/name=\"$t\"/& enabled=\"false\"/" "$testng"
        fi
    done
    rm -f "$dir/$TEST_MODULE/src/test/resources/"*.bak
}

# --------------------------------------------------------------------------------------------------------------
# 3. Run the shards concurrently.
# --------------------------------------------------------------------------------------------------------------
declare -a PIDS=() DIRS=() NAMES=()
START=$(date +%s)

for i in $(seq 1 "$SHARDS"); do
    var="SHARD_$i"; enabled="${!var:-}"
    [ -n "$enabled" ] || { log "No shard definition for $i"; exit 1; }
    offset=$(( BASE_OFFSET + (i - 1) * OFFSET_STEP ))
    dir="$WORKDIR/shard-$i"

    log "Shard $i: offset=$offset (IS https $((9443 + offset)), tomcat $((8080 + offset)), ldap $((10389 + offset)))"
    prepare_shard "$i" "$offset" "$dir" "$enabled"

    (
        cd "$dir"
        mvn test -pl "$TEST_MODULE" \
            -Dport.offset="$offset" \
            -Dcarbon.zip="$CARBON_ZIP" \
            --batch-mode > "$WORKDIR/shard-$i.log" 2>&1
    ) &
    PIDS+=($!); DIRS+=("$dir"); NAMES+=("$i")
done

log "Running $SHARDS shards concurrently..."
FAILED=0
for idx in "${!PIDS[@]}"; do
    if wait "${PIDS[$idx]}"; then
        log "Shard ${NAMES[$idx]} PASSED"
    else
        log "Shard ${NAMES[$idx]} FAILED  (see $WORKDIR/shard-${NAMES[$idx]}.log)"
        FAILED=1
    fi
done

# --------------------------------------------------------------------------------------------------------------
# 4. Report.
# --------------------------------------------------------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START ))
echo
echo "=============================================================="
printf "Wall clock: %d min %d sec across %d shards\n" $((ELAPSED / 60)) $((ELAPSED % 60)) "$SHARDS"
for idx in "${!NAMES[@]}"; do
    n=${NAMES[$idx]}
    printf "  shard %s: %s\n" "$n" "$(grep -hoE 'Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+' "$WORKDIR/shard-$n.log" | tail -1)"
done
echo "=============================================================="

exit $FAILED
