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
 *
 * The normal behavior also handles downloads. When the request carries a downloadTo path, the mock
 * writes downloadBody to that path and answers the way a current executable does.
 */
component accessors="true" {

	// Valid values: normal, timeout, noFile, errorResponse, malformed, oldHelper, downloadError,
	// or partialThenFail.
	property name="behavior";
	property name="response"; // Response struct written when behavior is normal.
	property name="downloadBody"; // Bytes written to downloadTo when the request asks for a download.
	property name="lastRequest"; // Most recent request struct written by CloudScraper.
	property name="lastCommand"; // Most recent command array created by CloudScraper.

	function init(){
		variables.behavior     = "normal";
		variables.response     = defaultResponse();
		variables.downloadBody = charsetDecode( "id,name#chr( 13 )##chr( 10 )#1,Test", "utf-8" );
		variables.lastRequest  = {};
		variables.lastCommand  = [];
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
			case "oldHelper":
				// Answer the way a 1.0.1 executable does: ignore downloadTo, return the whole body,
				// and leave out the two keys a current executable always sends.
				var legacy = duplicate( variables.response );
				structDelete( legacy, "downloadedTo" );
				structDelete( legacy, "bytesWritten" );
				fileWrite( resPath, serializeJSON( legacy ) );
				return {
					"exitCode" : 0,
					"timedOut" : false,
					"logPath"  : arguments.logPath
				};
			case "downloadError":
				// The site answered with an error, so the executable left the target file alone.
				var errorResponse               = duplicate( variables.response );
				errorResponse[ "statusCode" ]   = 403;
				errorResponse[ "statusText" ]   = "Forbidden";
				errorResponse[ "downloadedTo" ] = "";
				errorResponse[ "bytesWritten" ] = 0;
				errorResponse[ "bodyBase64" ]   = binaryEncode(
					charsetDecode( "<h1>Forbidden</h1>", "utf-8" ),
					"base64"
				);
				fileWrite( resPath, serializeJSON( errorResponse ) );
				return {
					"exitCode" : 0,
					"timedOut" : false,
					"logPath"  : arguments.logPath
				};
			case "partialThenFail":
				// Leave a half-written download behind, then time out, so a test can prove that
				// CloudScraper deletes the leftover file.
				var partPath = variables.lastRequest.downloadPartPath ?: "";
				if ( len( partPath ) ) {
					fileWrite( partPath, "half a file" );
				}
				return {
					"exitCode" : -1,
					"timedOut" : true,
					"logPath"  : arguments.logPath
				};
			default:
				fileWrite( resPath, serializeJSON( downloadAwareResponse() ) );
				return {
					"exitCode" : 0,
					"timedOut" : false,
					"logPath"  : arguments.logPath
				};
		}
	}

	/**
	 * Return the response for the normal behavior.
	 *
	 * When the request asked for a download, write downloadBody to the target and answer the way a
	 * current executable does: the two download keys are filled in and bodyBase64 is empty.
	 */
	private struct function downloadAwareResponse(){
		var target = variables.lastRequest.downloadTo ?: "";
		if ( !len( target ) ) {
			return variables.response;
		}

		fileWrite( target, variables.downloadBody );

		var downloaded               = duplicate( variables.response );
		downloaded[ "bodyBase64" ]   = "";
		downloaded[ "downloadedTo" ] = target;
		downloaded[ "bytesWritten" ] = getFileInfo( target ).size;
		return downloaded;
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
			"bodyBase64"   : binaryEncode( charsetDecode( "Hello, cbcloudscraper!", "utf-8" ), "base64" ),
			"bodyCharset"  : "utf-8",
			// A current executable always sends these two, even when no download was requested.
			"downloadedTo" : "",
			"bytesWritten" : 0,
			"error"        : ""
		};
	}

}
