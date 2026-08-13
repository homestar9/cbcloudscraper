/**
 * Makes HTTP requests to sites that use Cloudflare protection.
 *
 * Inject CloudScraper@cbcloudscraper into a model or handler. Then call get() or post(). Each
 * request starts the bundled executable once. By default, the executable tries curl_cffi first.
 * curl_cffi copies the TLS fingerprint used by a real browser. If that fails, the executable
 * tries cloudscraper, which handles older Cloudflare JavaScript challenges.
 *
 * The result struct uses the same basic shape as a cfhttp result. An HTTP 4xx or 5xx status is
 * still a valid response, so ok remains true and statusCode contains the site's status. A problem
 * running the executable sets ok to false and adds errorDetail. Set options.throwOnError to true
 * when the code should throw these process errors instead.
 *
 * Set options.downloadTo to an absolute path to send a large response straight to a file. The
 * executable writes the file in chunks, so the body never travels through base64 or through CFML
 * memory. See the "Download a large file" section of README.md.
 */
component singleton accessors="true" {

	property name="settings"          inject="coldbox:moduleSettings:cbcloudscraper";
	property name="runner"            inject="ProcessRunner@cbcloudscraper";
	property name="cookieJar"         inject="CookieJar@cbcloudscraper";
	property name="binaryProvisioner" inject="BinaryProvisioner@cbcloudscraper";
	property name="fileUtil"          inject="FileUtil@cbcloudscraper";
	property name="logger"            inject="logbox:logger:{this}";

	// This semaphore limits how many executable processes can run at once. onDIComplete creates
	// the semaphore after WireBox injects the settings. An empty string means there is no limit.
	variables.semaphore = "";

	// Millisecond timer value used to schedule temporary-file cleanup. onDIComplete sets this value
	// after startup cleanup. claimSweep updates it before recurring cleanup starts. Zero means no
	// cleanup time has been recorded.
	variables.lastSweepAt = 0;

	function init(){
		return this;
	}

	/**
	 * Set the process limit after WireBox finishes dependency injection. Also remove temporary
	 * files that may remain after an earlier crash.
	 */
	function onDIComplete(){
		var maxProcesses = settings.maxConcurrentProcesses ?: 0;
		if ( maxProcesses > 0 ) {
			variables.semaphore = createObject( "java", "java.util.concurrent.Semaphore" ).init(
				javacast( "int", maxProcesses )
			);
		}
		try {
			sweepTempFiles();
		} catch ( any e ) {
			// Startup can continue because an old temporary file does not stop new requests.
			logger.debug( "cbcloudscraper startup temp sweep failed: " & e.message );
		}
		variables.lastSweepAt = getTickCount();
		return this;
	}

	/**
	 * Make a GET request.
	 *
	 * @url     The address to fetch.
	 * @options Optional engine, impersonate, timeout, headers, followRedirects, verifySSL, proxy, useCookieCache, throwOnError, downloadTo, downloadOnlyOn2xx, and decodeText values.
	 */
	struct function get( required string url, struct options = {} ){
		return send( buildRequest( arguments.url, "GET", "", arguments.options ) );
	}

	/**
	 * Make a POST request.
	 *
	 * @url     The address to post to.
	 * @body    A string, binary value, or struct of form fields. A struct is sent as application/x-www-form-urlencoded.
	 * @options Optional overrides, same as get().
	 */
	struct function post(
		required string url,
		any body       = "",
		struct options = {}
	){
		return send(
			buildRequest(
				arguments.url,
				"POST",
				arguments.body,
				arguments.options
			)
		);
	}

	/**
	 * Find or download the executable without making an HTTP request. Call this during startup or
	 * from a scheduled task when the first real request should not wait for a download.
	 *
	 * @return The absolute path to the ready-to-run executable.
	 */
	string function warmup(){
		return binaryProvisioner.ensureBinary();
	}

	/**
	 * Run a prepared request struct. get() and post() both call this method.
	 *
	 * @request A normalized request struct (see buildRequest for the shape).
	 */
	struct function send( required struct request ){
		var started  = getTickCount();
		var req      = arguments.request;
		var uuid     = createUUID();
		var tmp      = settings.workingDirectory;
		var reqPath  = tmp & "/cbcs-" & uuid & ".req.json";
		var resPath  = tmp & "/cbcs-" & uuid & ".res.json";
		var logPath  = tmp & "/cbcs-" & uuid & ".log";
		var domain   = extractDomain( req.url );
		var acquired = false;

		// Use one cookie file per domain when cookie caching is enabled for this request.
		var jarPath = "";
		if ( req.useCookieCache ) {
			jarPath = cookieJar.pathFor( domain );
		}
		req[ "cookieJarPath" ] = jarPath;

		// Name the in-progress file for a download. The executable writes here and renames the
		// finished file onto the target. The file sits beside the target so the rename stays on
		// one volume, which is what makes it atomic. Eight characters of the request's UUID keep
		// two downloads of the same target apart without making the path much longer, which
		// matters because Windows still limits many paths to 260 characters.
		var downloadTo = structKeyExists( req, "downloadTo" ) ? req.downloadTo : "";
		var partPath   = "";
		if ( len( downloadTo ) ) {
			partPath = downloadTo & ".cbcs-" & left( replace( uuid, "-", "", "all" ), 8 ) & ".part";
			sweepDownloadParts( downloadTo );
		}
		req[ "downloadPartPath" ] = partPath;

		try {
			// Find or download the executable. The catch block below reports any setup failure.
			var binary = binaryProvisioner.ensureBinary();

			acquired = acquireSlot();

			writeUtf8File( reqPath, serializeJSON( req ) );

			var command = [
				binary,
				"--request",
				reqPath,
				"--response",
				resPath
			];

			// Give the executable time to write its response after the HTTP timeout ends.
			var processTimeout = ( req.timeoutSeconds ?: settings.defaultTimeout ) + 5;

			var runResult = runWithOptionalCookieLock( jarPath, function(){
				return runner.run(
					command        = command,
					logPath        = logPath,
					timeoutSeconds = processTimeout,
					env            = { "PYTHONUTF8" : "1", "PYTHONIOENCODING" : "utf-8" },
					workingDir     = tmp
				);
			} );

			if ( runResult.timedOut ) {
				return failure(
					req,
					"The request exceeded the " & req.timeoutSeconds & " second timeout.",
					logPath,
					started
				);
			}

			if ( !fileExists( resPath ) ) {
				return failure(
					req,
					"The scraper produced no response (exit code " & runResult.exitCode & "). " & tailLog(
						logPath
					),
					logPath,
					started
				);
			}

			var raw = deserializeJSON( fileRead( resPath, "utf-8" ) );

			if ( !( raw.ok ?: false ) ) {
				var message = "Unknown scraper error";
				if ( isStruct( raw.error ?: "" ) ) {
					message = raw.error.message ?: message;
				}
				return failure(
					req,
					"Scraper error: " & message,
					logPath,
					started
				);
			}

			return toResponse( raw, started, req );
		} catch ( any e ) {
			return failure(
				req,
				e.message & " " & ( e.detail ?: "" ),
				logPath,
				started
			);
		} finally {
			if ( acquired ) {
				releaseSlot();
			}
			safeDelete( reqPath );
			safeDelete( resPath );
			// Remove the download's in-progress file. This matters most on a timeout, because
			// ProcessRunner stops the executable with destroyForcibly() and it never gets a chance
			// to clean up after itself. On a successful download the file was already renamed to
			// the target, so safeDelete() finds nothing and does nothing.
			safeDelete( partPath );
			if ( !( settings.keepFailureLogs ?: false ) ) {
				safeDelete( logPath );
			}
			sweepIfDue();
		}
	}

	/**
	 * Delete leftover temporary request, response, and log files.
	 *
	 * This method deletes every matching file older than olderThanMinutes. This can include a file
	 * that another request is still using. Set olderThanMinutes higher than the longest time that
	 * one request can remain active.
	 *
	 * @olderThanMinutes Files older than this many minutes are removed. Omit to use the tempSweepMinutes setting.
	 *
	 * @return The number of temporary files removed.
	 */
	numeric function sweepTempFiles( numeric olderThanMinutes ){
		// The default is resolved inside the body because Adobe ColdFusion cannot compile a
		// dynamic expression as an argument default value.
		var maxAgeMinutes = structKeyExists( arguments, "olderThanMinutes" )
		 ? arguments.olderThanMinutes
		 : ( settings.tempSweepMinutes ?: 30 );
		var dir = settings.workingDirectory;
		if ( !len( dir ) || !directoryExists( dir ) ) {
			return 0;
		}
		var cutoff  = dateAdd( "n", -maxAgeMinutes, now() );
		var removed = 0;
		var rows    = directoryList( dir, false, "query", "cbcs-*" );
		for ( var row in rows ) {
			if ( row.type == "File" && row.dateLastModified < cutoff ) {
				safeDelete( dir & "/" & row.name );
				removed++;
			}
		}
		return removed;
	}

	// Private helpers

	/**
	 * Merge request options with the module defaults. Return the complete struct that is written
	 * to the executable's JSON request file.
	 */
	private struct function buildRequest(
		required string url,
		required string method,
		any body       = "",
		struct options = {}
	){
		var opts = arguments.options;

		// Resolve the download target first, because it decides which timeout default applies.
		var downloadTo = trim( opt( opts, "downloadTo", "" ) );
		if ( len( downloadTo ) ) {
			downloadTo = prepareDownloadTarget( downloadTo );
		}
		var fallbackTimeout = len( downloadTo )
		 ? ( settings.defaultDownloadTimeout ?: 300 )
		 : settings.defaultTimeout;

		// Check the key directly. Adobe ColdFusion's ?: operator treats a boolean false value like
		// a missing value, which would turn a configured false back into true.
		var onlyOn2xxDefault = structKeyExists( settings, "downloadOnlyOn2xx" )
		 ? settings.downloadOnlyOn2xx
		 : true;

		var req = {
			"url"               : arguments.url,
			"method"            : uCase( arguments.method ),
			"headers"           : duplicate( settings.defaultHeaders ?: {} ),
			"bodyBase64"        : "",
			"engine"            : opt( opts, "engine", settings.defaultEngine ),
			"impersonate"       : opt( opts, "impersonate", settings.impersonate ),
			"timeoutSeconds"    : opt( opts, "timeout", fallbackTimeout ),
			"downloadTo"        : downloadTo,
			"downloadOnlyOn2xx" : opt( opts, "downloadOnlyOn2xx", onlyOn2xxDefault ),
			// Only CFML reads this one. The executable ignores it.
			"decodeText"        : opt( opts, "decodeText", true ),
			"followRedirects"   : opt(
				opts,
				"followRedirects",
				settings.followRedirects
			),
			"verifySSL"      : opt( opts, "verifySSL", settings.verifySSL ),
			"proxy"          : opt( opts, "proxy", settings.proxy ),
			"defaultCharset" : settings.defaultCharset ?: "utf-8",
			"useCookieCache" : opt( opts, "useCookieCache", true ),
			"throwOnError"   : opt(
				opts,
				"throwOnError",
				settings.throwOnError ?: false
			)
		};

		// Request headers replace default headers with the same name and keep the other defaults.
		if ( structKeyExists( opts, "headers" ) && isStruct( opts.headers ) ) {
			structAppend( req.headers, opts.headers, true );
		}

		req.bodyBase64 = encodeBody( arguments.body, req );

		return req;
	}

	/**
	 * Check a downloadTo path and create the directory that will hold the file.
	 *
	 * The path must be absolute. A relative path would mean something different on each engine and
	 * operating system, so this method rejects it and tells the caller to run expandPath() instead.
	 * Failing here also means a bad path is caught before an executable process starts.
	 *
	 * @path The caller's downloadTo value.
	 *
	 * @return The path with forward slashes.
	 */
	private string function prepareDownloadTarget( required string path ){
		var target = replace( trim( arguments.path ), "\", "/", "all" );

		if ( !reFind( "^([a-zA-Z]:/|//|/)", target ) ) {
			throw(
				type    = "cbcloudscraper.InvalidOption",
				message = "The downloadTo option needs an absolute path.",
				detail  = "Received '" & arguments.path & "'. Pass a full path such as ""C:/data/file.csv"" or ""/var/data/file.csv"". Use expandPath() to turn an application-relative path into a full one."
			);
		}

		if ( directoryExists( target ) ) {
			throw(
				type    = "cbcloudscraper.InvalidOption",
				message = "The downloadTo option needs a file path, not a directory.",
				detail  = "'" & arguments.path & "' is an existing directory. Include the file name in the path."
			);
		}

		var parent = createObject( "java", "java.io.File" ).init( javacast( "string", target ) ).getParent();
		if ( !isNull( parent ) && len( parent ) ) {
			fileUtil.makeDirectory( parent );
		}

		return target;
	}

	/**
	 * Delete in-progress download files left beside a target by an earlier run.
	 *
	 * send()'s finally block removes this file when a request fails, but that only runs when the
	 * CFML process lives long enough. A server that is killed during a download leaves the file
	 * behind, and sweepTempFiles() never sees it because it only looks inside workingDirectory.
	 *
	 * Only files older than the cutoff are removed, so a download that is still running is left
	 * alone. The cutoff is at least one hour, because tempSweepMinutes describes short-lived
	 * request files and can be set lower than a large download takes.
	 *
	 * @target The downloadTo path for the request that is about to start.
	 */
	private void function sweepDownloadParts( required string target ){
		try {
			var file = createObject( "java", "java.io.File" ).init( javacast( "string", arguments.target ) );
			var dir  = file.getParent();
			if ( isNull( dir ) || !len( dir ) || !directoryExists( dir ) ) {
				return;
			}
			var cutoff = dateAdd(
				"n",
				-max( settings.tempSweepMinutes ?: 30, 60 ),
				now()
			);
			var rows = directoryList(
				dir,
				false,
				"query",
				file.getName() & ".cbcs-*.part"
			);
			for ( var row in rows ) {
				if ( row.type == "File" && row.dateLastModified < cutoff ) {
					safeDelete( dir & "/" & row.name );
				}
			}
		} catch ( any e ) {
			// A problem reading the target's directory must not stop the download itself.
			logger.debug( "cbcloudscraper could not check for leftover download files: " & e.message );
		}
	}

	/**
	 * Convert the request body to base64. Encode structs as URL-encoded forms. Keep binary values
	 * unchanged before base64 encoding. Encode strings as UTF-8 bytes.
	 */
	private string function encodeBody( any body, required struct req ){
		if ( isNull( arguments.body ) ) {
			return "";
		}

		if ( isStruct( arguments.body ) ) {
			var pairs = [];
			for ( var key in arguments.body ) {
				pairs.append( urlEncodedFormat( key ) & "=" & urlEncodedFormat( arguments.body[ key ] ) );
			}
			if ( !hasHeader( arguments.req.headers, "content-type" ) ) {
				arguments.req.headers[ "Content-Type" ] = "application/x-www-form-urlencoded";
			}
			return binaryEncode( charsetDecode( arrayToList( pairs, "&" ), "utf-8" ), "base64" );
		}

		if ( isBinary( arguments.body ) ) {
			return binaryEncode( arguments.body, "base64" );
		}

		if ( isSimpleValue( arguments.body ) && len( arguments.body ) ) {
			return binaryEncode( charsetDecode( toString( arguments.body ), "utf-8" ), "base64" );
		}

		return "";
	}

	/**
	 * Convert the executable's response into a result shaped like cfhttp output.
	 *
	 * @raw     The response struct read from the executable's response file.
	 * @started The tick count taken when the request began.
	 * @request The request struct that produced this response.
	 */
	private struct function toResponse(
		required struct raw,
		required numeric started,
		required struct request
	){
		var download  = resolveDownload( arguments.raw, arguments.request );
		var bodyBytes = download.bodyBytes;
		var charset   = arguments.raw.bodyCharset ?: ( settings.defaultCharset ?: "utf-8" );

		// Skip the text copy when the body went to a file, and when the caller asked for bytes
		// only. charsetEncode() builds a second full copy of the body as a CFML string, which for
		// a large response can cost more heap than the bytes themselves.
		var wantsText = !len( download.downloadedTo )
		&& ( structKeyExists( arguments.request, "decodeText" ) ? arguments.request.decodeText : true );

		var text = "";
		if ( wantsText ) {
			try {
				text = charsetEncode( bodyBytes, charset );
			} catch ( any e ) {
				// Use UTF-8 when the CFML engine does not support the response's character set.
				text    = charsetEncode( bodyBytes, "utf-8" );
				charset = "utf-8";
			}
		}

		// Build a case-insensitive header struct for simple lookups. The last duplicate value wins.
		// rawHeaders keeps every original header, including repeated Set-Cookie headers.
		var headerStruct = {};
		for ( var header in ( arguments.raw.headers ?: [] ) ) {
			headerStruct[ header.name ] = header.value;
		}

		return {
			"ok"                  : true,
			"statusCode"          : arguments.raw.statusCode ?: 0,
			"statusText"          : arguments.raw.statusText ?: "",
			"headers"             : headerStruct,
			"rawHeaders"          : arguments.raw.headers ?: [],
			"cookies"             : arguments.raw.cookies ?: [],
			"fileContent"         : text,
			"fileContentAsBinary" : bodyBytes,
			"charset"             : charset,
			"finalUrl"            : arguments.raw.finalUrl ?: "",
			"engineUsed"          : arguments.raw.engineUsed ?: "",
			"downloadedTo"        : download.downloadedTo,
			"bytesWritten"        : download.bytesWritten,
			"executionTime"       : getTickCount() - arguments.started,
			"errorDetail"         : ""
		};
	}

	/**
	 * Work out what happened to the response body, and write the file when the executable did not.
	 *
	 * A current executable handles downloadTo itself and reports downloadedTo in its response. An
	 * executable older than this module does not know the option, ignores it, and returns the whole
	 * body as usual. A missing downloadedTo key is how this method tells the two apart.
	 *
	 * @raw     The response struct read from the executable's response file.
	 * @request The request struct that produced this response.
	 *
	 * @return A struct with bodyBytes, downloadedTo, and bytesWritten.
	 */
	private struct function resolveDownload( required struct raw, required struct request ){
		var bodyBytes = binaryDecode( arguments.raw.bodyBase64 ?: "", "base64" );
		var target    = structKeyExists( arguments.request, "downloadTo" ) ? arguments.request.downloadTo : "";

		if ( !len( target ) ) {
			return {
				"bodyBytes"    : bodyBytes,
				"downloadedTo" : "",
				"bytesWritten" : 0
			};
		}

		if ( structKeyExists( arguments.raw, "downloadedTo" ) ) {
			return {
				"bodyBytes"    : bodyBytes,
				"downloadedTo" : arguments.raw.downloadedTo,
				"bytesWritten" : arguments.raw.bytesWritten ?: 0
			};
		}

		// The executable is older than this module. Write the file here so the option still works,
		// and say so, because this path loses every memory saving the option exists for.
		logger.warn(
			"cbcloudscraper wrote the downloadTo file itself because the helper executable is older than this module and does not support downloads. Update the helper to get the memory savings. Run CloudScraper.warmup() after clearing the bin directory, or set autoDownloadBinary to true."
		);

		// Only a 2xx body is written on this path. CFML cannot tell a Cloudflare block page from a
		// real response the way the current executable can, so honoring downloadOnlyOn2xx=false
		// here could replace a good file with a block page.
		var status = arguments.raw.statusCode ?: 0;
		if ( status < 200 || status >= 300 ) {
			return {
				"bodyBytes"    : bodyBytes,
				"downloadedTo" : "",
				"bytesWritten" : 0
			};
		}

		fileWrite( target, bodyBytes );
		return {
			// Empty, so a caller sees the same result whichever executable answered.
			"bodyBytes"    : binaryDecode( "", "base64" ),
			"downloadedTo" : target,
			"bytesWritten" : getFileInfo( target ).size
		};
	}

	/**
	 * Return an ok=false result for a process failure. Throw an exception when throwOnError is true.
	 */
	private struct function failure(
		required struct request,
		required string detail,
		required string logPath,
		required numeric started
	){
		if ( arguments.request.throwOnError ?: false ) {
			throw(
				type    = "cbcloudscraper.RequestException",
				message = "cbcloudscraper request failed",
				detail  = arguments.detail
			);
		}
		return {
			"ok"                  : false,
			"statusCode"          : 0,
			"statusText"          : "",
			"headers"             : {},
			"rawHeaders"          : [],
			"cookies"             : [],
			"fileContent"         : "",
			// An empty byte array, so the type matches the success path.
			"fileContentAsBinary" : binaryDecode( "", "base64" ),
			"charset"             : settings.defaultCharset ?: "utf-8",
			"finalUrl"            : "",
			"engineUsed"          : "",
			"downloadedTo"        : "",
			"bytesWritten"        : 0,
			"executionTime"       : getTickCount() - arguments.started,
			"errorDetail"         : arguments.detail
		};
	}

	/**
	 * Clean temporary files when the configured time has passed.
	 *
	 * Startup cleanup cannot remove files left by requests that fail later. send() calls this
	 * method after every request so a long-running server can remove those files. The method
	 * returns without locking or reading the directory when cleanup is not due.
	 */
	private void function sweepIfDue(){
		try {
			var minutes = settings.tempSweepMinutes ?: 30;
			// Zero or a negative value disables cleanup after requests.
			if ( minutes <= 0 || !claimSweep( minutes ) ) {
				return;
			}
			sweepTempFiles( minutes );
		} catch ( any e ) {
			// Cleanup errors must not change the completed request's result.
			logger.debug( "cbcloudscraper could not run scheduled temp-file cleanup: " & e.message );
		}
	}

	/**
	 * Return true when this thread should run the next cleanup.
	 *
	 * The first check avoids taking the lock when cleanup is not due. The second check runs
	 * inside the lock. It prevents two threads from claiming the same cleanup interval. The thread
	 * that claims the interval records the time before cleanup starts.
	 *
	 * @minutes How many minutes must pass between cleanup runs.
	 */
	private boolean function claimSweep( required numeric minutes ){
		if ( isSweepRecent( arguments.minutes ) ) {
			return false;
		}
		var claimed= false;
		lock name  ="cbcs-sweep-#hash( settings.workingDirectory, "MD5" )#" type="exclusive" timeout="5" {
			if ( !isSweepRecent( arguments.minutes ) ) {
				variables.lastSweepAt = getTickCount();
				claimed               = true;
			}
		}
		return claimed;
	}

	/**
	 * Return true when the last cleanup claim was less than minutes ago.
	 *
	 * @minutes How many minutes must pass between cleanup runs.
	 */
	private boolean function isSweepRecent( required numeric minutes ){
		if ( variables.lastSweepAt <= 0 ) {
			return false;
		}
		return ( getTickCount() - variables.lastSweepAt ) < ( arguments.minutes * 60000 );
	}

	/**
	 * Lock one domain's cookie file while a request uses it. This prevents two requests from
	 * changing the same file at once. Requests for different domains can still run together.
	 */
	private any function runWithOptionalCookieLock( required string jarPath, required any invoker ){
		var fn = arguments.invoker;
		if ( !len( arguments.jarPath ) ) {
			return fn();
		}
		var result= "";
		lock name ="cbcs-jar-#hash( arguments.jarPath, "MD5" )#" type="exclusive" timeout="60" {
			result = fn();
		}
		return result;
	}

	private boolean function acquireSlot(){
		if ( isSimpleValue( variables.semaphore ) ) {
			return false; // No process limit is configured.
		}
		var jTimeUnit = createObject( "java", "java.util.concurrent.TimeUnit" );
		var waitFor   = settings.acquireTimeout ?: 20;
		if ( !variables.semaphore.tryAcquire( javacast( "long", waitFor ), jTimeUnit.SECONDS ) ) {
			throw(
				type    = "cbcloudscraper.Busy",
				message = "No scraper process slot became available within " & waitFor & " seconds."
			);
		}
		return true;
	}

	private void function releaseSlot(){
		if ( !isSimpleValue( variables.semaphore ) ) {
			variables.semaphore.release();
		}
	}

	/**
	 * Write a UTF-8 file without a byte-order mark. Use a Java stream because Adobe ColdFusion's
	 * fileWrite function does not accept a character set. This keeps the output consistent on all
	 * supported CFML engines.
	 */
	private void function writeUtf8File( required string path, required string content ){
		var stream = createObject( "java", "java.io.FileOutputStream" ).init(
			javacast( "string", arguments.path )
		);
		try {
			stream.write( charsetDecode( arguments.content, "utf-8" ) );
		} finally {
			stream.close();
		}
	}

	private string function tailLog( required string logPath ){
		if ( !len( arguments.logPath ) || !fileExists( arguments.logPath ) ) {
			return "";
		}
		try {
			var content = fileRead( arguments.logPath, "utf-8" );
			return "Diagnostic log: " & ( len( content ) > 500 ? right( content, 500 ) : content );
		} catch ( any e ) {
			return "";
		}
	}

	private void function safeDelete( required string path ){
		try {
			if ( len( arguments.path ) && fileExists( arguments.path ) ) {
				fileDelete( arguments.path );
			}
		} catch ( any e ) {
			// Record the error for debugging. A later cleanup can remove the file.
			logger.debug( "cbcloudscraper could not delete temp file '" & arguments.path & "': " & e.message );
		}
	}

	private string function extractDomain( required string url ){
		var host = reReplaceNoCase( arguments.url, "^https?://", "", "one" );
		host     = listFirst( host, "/" );
		host     = listFirst( host, "?" );
		// Remove login information before @ and the port after the host name.
		if ( find( "@", host ) ) {
			host = listLast( host, "@" );
		}
		host = listFirst( host, ":" );
		return lCase( host );
	}

	private boolean function hasHeader( required struct headers, required string name ){
		for ( var key in arguments.headers ) {
			if ( lCase( key ) == lCase( arguments.name ) ) {
				return true;
			}
		}
		return false;
	}

	/**
	 * Return a struct value or its fallback. CFML engines do not handle the ?: operator the same
	 * way when a struct key is missing, so this method checks the key directly. The fallback is
	 * returned with isNull() instead of ?: because Adobe ColdFusion's ?: treats a boolean false
	 * value like a missing value and would replace it.
	 */
	private any function opt(
		required struct options,
		required string key,
		any fallback
	){
		if ( structKeyExists( arguments.options, arguments.key ) ) {
			return arguments.options[ arguments.key ];
		}
		return isNull( arguments.fallback ) ? "" : arguments.fallback;
	}

}
