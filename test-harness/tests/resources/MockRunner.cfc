/**
 * Replaces ProcessRunner during unit tests.
 *
 * The real ProcessRunner starts the packaged executable. That file may not be available on the
 * current operating system or before a build. Tests inject this mock into CloudScraper so they
 * can cover request files, response files, body decoding, headers, cookies, cleanup, and error
 * handling without starting the real executable.
 *
 * The mock saves the request written by CloudScraper and writes a fixed response file. Tests can
 * then check both sides of the exchange. Set behavior to simulate a timeout, missing response
 * file, nonzero exit code, or invalid response data.
 */
component accessors="true" {

	property name="behavior"; // Valid values: normal, timeout, noFile, errorResponse, or malformed.
	property name="response"; // Response struct written when behavior is normal.
	property name="lastRequest"; // Most recent request struct written by CloudScraper.
	property name="lastCommand"; // Most recent command array created by CloudScraper.

	function init(){
		variables.behavior    = "normal";
		variables.response    = defaultResponse();
		variables.lastRequest = {};
		variables.lastCommand = [];
		return this;
	}

	/**
	 * Match ProcessRunner.run(). Save the request, write a fixed response, and return the same
	 * result fields as the real runner.
	 */
	struct function run(
		required array command,
		required string logPath,
		required numeric timeoutSeconds,
		struct env        = {},
		string workingDir = ""
	){
		variables.lastCommand = arguments.command;

		// The command contains: binaryPath, --request, request path, --response, response path.
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
				// Return a nonzero exit code without creating a response file.
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
	 * Return a successful response with a fixed body, two headers, and one cookie.
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
