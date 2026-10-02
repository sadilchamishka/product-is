#!/usr/bin/env python3
"""Generates the per-fork inputs needed to run the integration suite as concurrent shards.

Surefire hands each <suiteXmlFile> to a different forked JVM when forkCount > 1. Each of those forks starts its own
Identity Server, so every fork needs its own ports and its own automation.xml to read them from. This script writes,
for each shard N:

  <build-dir>/shards/shard-N.xml        the suite, with the <test> blocks that belong to other shards disabled
  <build-dir>/fork-N/resources/         a copy of src/test/resources with automation.xml pinned to shard N's ports

testng.xml stays the single source of truth; the shard files are derived from it on every build.

Usage: generate-test-shards.py <resources-dir> <build-dir> <shard-count>
"""
import os
import re
import shutil
import sys

# The split is the one the GitHub "Integration Test Runner" workflow uses, which is known to balance well.
SHARDS = [
    "is-tests-default-configuration,is-test-rest-api,is-test-webhooks,is-tests-scim2,"
    "is-test-adaptive-authentication",

    "is-test-adaptive-authentication-nashorn,is-test-adaptive-authentication-nashorn-with-restart,"
    "is-tests-default-configuration-ldap,is-tests-uuid-user-store,is-tests-federation,is-tests-federation-restart",

    "is-tests-oauth-client-secrets,is-tests-jdbc-userstore,is-tests-read-only-userstore,"
    "is-tests-oauth-jwt-token-gen-enabled,is-tests-email-username,is-tests-saml-query-profile,"
    "is-tests-default-encryption,is-test-session-mgt,is-tests-password-update-api",

    "is-tests-with-individual-configuration-changes",
]

# is-tests-initialize is not listed: it starts Tomcat, LDAP and the SMTP server and must run in every shard.
BASE_OFFSET = 410
OFFSET_STEP = 10          # Federation suites start a secondary server at offset+1, so shards cannot be adjacent.
CARBON_HTTPS = 9443
CARBON_HTTP = 9763
SMTP_PORT = 3025


def shard_names(count):
    """Splits the configured shards into `count` buckets, merging them when fewer shards are asked for."""
    if count >= len(SHARDS):
        return SHARDS[:count]
    buckets = [[] for _ in range(count)]
    for i, s in enumerate(SHARDS):
        buckets[i % count].append(s)
    return [",".join(b) for b in buckets]


def all_test_names(testng):
    return re.findall(r'<test name="([^"]+)"', testng)


def write_suite(testng, enabled, path):
    """Writes a copy of testng.xml with every <test> block outside `enabled` marked enabled="false"."""
    keep = set(enabled.split(",")) | {"is-tests-initialize"}
    out = testng
    for name in all_test_names(testng):
        if name not in keep:
            out = out.replace(f'<test name="{name}"', f'<test name="{name}" enabled="false"', 1)
    with open(path, "w") as f:
        f.write(out)
    return len(keep)


def write_resources(src, dest, offset):
    """Copies the test resources and pins automation.xml to this shard's ports."""
    if os.path.exists(dest):
        shutil.rmtree(dest)
    shutil.copytree(src, dest)

    path = os.path.join(dest, "automation.xml")
    s = open(path).read()

    # The offset the framework starts this shard's server with.
    s = re.sub(r'(<parameter name="-DportOffset" value=")\d+(")', lambda m: f"{m.group(1)}{offset}{m.group(2)}", s)

    # identity001 is this shard's server; identity002 and identity003 are the secondary servers some suites start.
    for n in (1, 2, 3):
        off = offset + n - 1
        s = re.sub(
            r'(<instance name="identity%03d".*?<ports>.*?<port type="http">)\d+'
            r'(</port>\s*<port type="https">)\d+(</port>)' % n,
            lambda m: f"{m.group(1)}{CARBON_HTTP + off}{m.group(2)}{CARBON_HTTPS + off}{m.group(3)}",
            s, flags=re.S)

    # The test SMTP server moves with the shard too.
    s = re.sub(r"(<port>)%d(</port>)" % SMTP_PORT,
               lambda m: f"{m.group(1)}{SMTP_PORT + offset - BASE_OFFSET}{m.group(2)}", s)

    open(path, "w").write(s)


def main():
    resources, build_dir, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
    testng = open(os.path.join(resources, "testng.xml")).read()

    shards_dir = os.path.join(build_dir, "shards")
    os.makedirs(shards_dir, exist_ok=True)

    for i, enabled in enumerate(shard_names(count), start=1):
        offset = BASE_OFFSET + (i - 1) * OFFSET_STEP
        suite = os.path.join(shards_dir, f"shard-{i}.xml")
        kept = write_suite(testng, enabled, suite)
        write_resources(resources, os.path.join(build_dir, f"fork-{i}", "resources"), offset)
        print(f"shard {i}: offset={offset} https={CARBON_HTTPS + offset} "
              f"tomcat={8080 + offset} ldap={10389 + offset} tests={kept}")


if __name__ == "__main__":
    main()
