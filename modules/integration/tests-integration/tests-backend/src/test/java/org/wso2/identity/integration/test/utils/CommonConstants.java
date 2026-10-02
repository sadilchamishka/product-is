/*
*Copyright (c) 2005-2015, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
*
*WSO2 Inc. licenses this file to you under the Apache License,
*Version 2.0 (the "License"); you may not use this file except
*in compliance with the License.
*You may obtain a copy of the License at
*
*http://www.apache.org/licenses/LICENSE-2.0
*
*Unless required by applicable law or agreed to in writing,
*software distributed under the License is distributed on an
*"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
*KIND, either express or implied.  See the License for the
*specific language governing permissions and limitations
*under the License.
*/
package org.wso2.identity.integration.test.utils;

public class CommonConstants {

    /**
     * Port offset applied to every server this suite starts. Overridable with -Dport.offset so that several shards of
     * the suite can run concurrently on one machine without colliding. Defaults to the historical value of 410.
     */
    private static final int DEFAULT_OFFSET = 410;
    private static final int OFFSET_STEP = 10;

    /**
     * Which shard of the suite this JVM is running. Surefire sets it from ${surefire.forkNumber} under the
     * parallel-tests profile, so each fork lands on its own ports. Defaults to 1, the single-server case.
     */
    private static final int SHARD_NUMBER = Integer.getInteger("shard.number", 1);

    public static final int IS_DEFAULT_OFFSET =
            Integer.getInteger("port.offset", DEFAULT_OFFSET + (SHARD_NUMBER - 1) * OFFSET_STEP);

    private static final int CARBON_DEFAULT_HTTPS_PORT = 9443;
    private static final int TOMCAT_BASE_PORT = 8080;

    public static final int IS_DEFAULT_HTTPS_PORT = CARBON_DEFAULT_HTTPS_PORT + IS_DEFAULT_OFFSET;

    /**
     * Port of the Tomcat instance that hosts the sample applications. Derived from the same offset so that it moves
     * with the rest of the shard, and separately overridable with -Dtomcat.port.
     */
    public static final int DEFAULT_TOMCAT_PORT = Integer.getInteger("tomcat.port", TOMCAT_BASE_PORT + IS_DEFAULT_OFFSET);

    public static final String DEFAULT_SERVICE_URL = "https://localhost:" + IS_DEFAULT_HTTPS_PORT + "/services/";
    public static final String SAML_REQUEST_PARAM = "SAMLRequest";
    public static final String SAML_RESPONSE_PARAM = "SAMLResponse";
    public static final String SESSION_DATA_KEY = "name=\"sessionDataKey\"";
    public static final String USER_DOES_NOT_EXIST = "17001";
    public static final String INVALID_CREDENTIAL = "17002";
    public static final String USER_IS_LOCKED = "17003";
    public static final String BASIC_AUTHENTICATOR="BasicAuthenticator";
    public static final String USER_AGENT_HEADER = "User-Agent";

    public enum AdminClients {
        IDENTITY_PROVIDER_MGT_SERVICE_CLIENT,
        APPLICATION_MANAGEMENT_SERVICE_CLIENT,
        USER_MANAGEMENT_CLIENT
    }



}
