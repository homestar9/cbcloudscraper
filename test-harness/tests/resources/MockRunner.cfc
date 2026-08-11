/**
 * Test stand-in for ProcessRunner.
 *
 * The real ProcessRunner launches the packaged executable, which only exists on Windows
 * after a build. This mock is injected into CloudScraper during unit tests so the whole
 * CFML path (building the request file, reading the response file, decoding the body,
 * mapping headers and cookies, cleaning up, error handling) can be exercised on any
 * engine and operating system without the real binary.
 *
 * It records the request that CloudScraper wrote, and writes a canned response file, so
 * tests can assert on both what was sent and what comes back. Set "behavior" to make it
 * simulate a timeout, a missing response file, a non-zero exit, or malformed output.
 */
component accessors="true" {

	property name="behavior"; // normal | timeout | noFile | errorResponse | malformed
	property name="response"; // struct written as the response for "normal"
	property name="lastRequest"; // the request struct CloudScraper wrote
	property name="lastCommand"; // the command array CloudScraper passed

	function init(){
		variables.behavior    = "normal";
		variables.response    = defaultResponse();
		variables.lastRequest = {};
		variables.lastCommand = [];
		return this;
	}

	/**
	 * Mimic ProcessRunner.run: record the request, write a canned response, and return a
	 * result struct with the same shape the real runner returns.
	 */
	struct function run(
		required array command,
		required string logPath,
		required numeric timeoutSeconds,
		struct env        = {},
		string workingDir = ""
	){
		variables.lastCommand = arguments.command;

		// command layout: [ binaryPath, "--request", reqPath, "--response", resPath ]
		var reqPath = arguments.command[ 3 ];
		var resPath = arguments.command[ 5 ];

		if ( fileExists( reqPath ) ) {
			variables.lastRequest = deserializeJSON( fileRead( reqPath, "utf-8" ) );
		}

		switch ( variables.behavior ) {
			case "timeout":
				return {
					"exitCode" : -1,
					"timedOut" : true,
					"logPath"  : arguments.logPath
				};
			case "noFile":
				// Return a non-zero exit and deliberately do not write the response file.
				return {
					"exitCode" : 1,
					"timedOut" : false,
					"logPath"  : arguments.logPath
				};
			case "malformed":
				fileWrite( resPath, "this is not valid json {" );
				return {
					"exitCode" : 0,
					"timedOut" : false,
					"logPath"  : arguments.logPath
				};
			case "errorResponse":
				fileWrite(
					resPath,
					serializeJSON( {
						"ok"    : false,
						"error" : { "type" : "worker", "message" : "boom" }
					} )
				);
				return {
					"exitCode" : 1,
					"timedOut" : false,
					"logPath"  : arguments.logPath
				};
			default:
				fileWrite( resPath, serializeJSON( variables.response ) );
				return {
					"exitCode" : 0,
					"timedOut" : false,
					"logPath"  : arguments.logPath
				};
		}
	}

	/**
	 * A successful response with a known body, two header lines, and one cookie.
	 */
	private struct function defaultResponse(){
		return {
			"ok"         : true,
			"statusCode" : 200,
			"statusText" : "OK",
			"finalUrl"   : "https://example.com/",
			"engineUsed" : "curl_cffi",
			"timingMs"   : 5,
			"headers"    : [
				{
					"name"  : "Content-Type",
					"value" : "text/html; charset=utf-8"
				},
				{ "name" : "Set-Cookie", "value" : "session=abc; Path=/" }
			],
			"cookies" : [
				{
					"name"    : "cf_clearance",
					"value"   : "xyz",
					"domain"  : ".example.com",
					"path"    : "/",
					"expires" : 0
				}
			],
			"bodyBase64"  : binaryEncode( charsetDecode( "Hello, cbcloudscraper!", "utf-8" ), "base64" ),
			"bodyCharset" : "utf-8",
			"error"       : ""
		};
	}

}
