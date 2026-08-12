/**
 * CloudScraper: make HTTP requests that try to pass Cloudflare protection.
 *
 * Inject this into your model or handler as CloudScraper@cbcloudscraper, then call get()
 * or post(). Each call runs the bundled executable once. The executable tries curl_cffi
 * first (which presents a real browser's TLS fingerprint) and falls back to cloudscraper
 * (which solves Cloudflare's legacy JavaScript challenge).
 *
 * The returned struct is shaped like the result of a cfhttp call, so it should feel
 * familiar. A 4xx or 5xx response from the site is NOT treated as an error; it comes back
 * with ok=true and the real status code, exactly as cfhttp behaves. Only an operational
 * failure (the binary is missing, the process times out, the output cannot be read)
 * returns ok=false with errorDetail set. Pass options.throwOnError=true to make those
 * operational failures throw instead.
 */
component singleton accessors="true" {

	property name="settings"          inject="coldbox:moduleSettings:cbcloudscraper";
	property name="runner"            inject="ProcessRunner@cbcloudscraper";
	property name="cookieJar"         inject="CookieJar@cbcloudscraper";
	property name="binaryProvisioner" inject="BinaryProvisioner@cbcloudscraper";
	property name="logger"            inject="logbox:logger:{this}";

	// Limits how many executable processes run at once. Built in onDIComplete because it
	// depends on the injected settings. Empty string means "no limit".
	variables.semaphore = "";

	function init(){
		return this;
	}

	/**
	 * Runs once after WireBox injects the dependencies. Sets up the process limit and
	 * clears any stale temporary files left by an earlier crash.
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
			// Housekeeping is best-effort; never block startup on it.
			logger.debug( "cbcloudscraper startup temp sweep failed: " & e.message );
		}
		return this;
	}

	/**
	 * Make a GET request.
	 *
	 * @url     The address to fetch.
	 * @options Optional overrides: engine, impersonate, timeout, headers, followRedirects, verifySSL, proxy, useCookieCache, throwOnError.
	 */
	struct function get( required string url, struct options = {} ){
		return send( buildRequest( arguments.url, "GET", "", arguments.options ) );
	}

	/**
	 * Make a POST request.
	 *
	 * @url     The address to post to.
	 * @body    The request body: a string, a binary value, or a struct of form fields (sent as application/x-www-form-urlencoded).
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
	 * Pre-fetch the executable now (downloading it if needed) without making a request. Useful
	 * at application startup or from a scheduled task so the first real request is not delayed.
	 *
	 * @return The absolute path to the ready-to-run executable.
	 */
	string function warmup(){
		return binaryProvisioner.ensureBinary();
	}

	/**
	 * Run a fully prepared request. Both get() and post() call this. Use it directly only
	 * when you have built the request struct yourself.
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

		// Decide whether this request uses a stored cookie file.
		var jarPath = "";
		if ( req.useCookieCache ) {
			jarPath = cookieJar.pathFor( domain );
		}
		req[ "cookieJarPath" ] = jarPath;

		try {
			// Resolve the executable, downloading it on first use if needed. A failure here
			// (missing binary, no network, checksum mismatch) is reported like any other
			// operational failure via the catch block below.
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

			// Give the process a little more time than the HTTP timeout so the worker can
			// finish writing its response before ProcessRunner would kill it.
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

			return toResponse( raw, started );
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
			if ( !( settings.keepFailureLogs ?: false ) ) {
				safeDelete( logPath );
			}
		}
	}

	/**
	 * Delete stored cookie files older than the configured age, plus any leftover
	 * temporary request/response files. Also callable on demand.
	 *
	 * @olderThanMinutes Files older than this many minutes are removed.
	 *
	 * @return The number of temporary files removed.
	 */
	numeric function sweepTempFiles( numeric olderThanMinutes = ( settings.tempSweepMinutes ?: 30 ) ){
		var dir = settings.workingDirectory;
		if ( !len( dir ) || !directoryExists( dir ) ) {
			return 0;
		}
		var cutoff  = dateAdd( "n", -arguments.olderThanMinutes, now() );
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

	/************************* PRIVATE HELPERS *************************/

	/**
	 * Merge the caller's loose options with the module defaults into the strict request
	 * struct that gets written to the JSON file for the executable.
	 */
	private struct function buildRequest(
		required string url,
		required string method,
		any body       = "",
		struct options = {}
	){
		var opts = arguments.options;

		var req = {
			"url"             : arguments.url,
			"method"          : uCase( arguments.method ),
			"headers"         : duplicate( settings.defaultHeaders ?: {} ),
			"bodyBase64"      : "",
			"engine"          : opt( opts, "engine", settings.defaultEngine ),
			"impersonate"     : opt( opts, "impersonate", settings.impersonate ),
			"timeoutSeconds"  : opt( opts, "timeout", settings.defaultTimeout ),
			"followRedirects" : opt(
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

		// Per-request headers add to or override the default headers.
		if ( structKeyExists( opts, "headers" ) && isStruct( opts.headers ) ) {
			structAppend( req.headers, opts.headers, true );
		}

		req.bodyBase64 = encodeBody( arguments.body, req );

		return req;
	}

	/**
	 * Turn the request body into a base64 string of its exact bytes. A struct is encoded
	 * as a URL-encoded form; a binary value is encoded as-is; a string is encoded as UTF-8.
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
	 * Convert the worker's raw response into the cfhttp-style result struct.
	 */
	private struct function toResponse( required struct raw, required numeric started ){
		var bodyBytes = binaryDecode( arguments.raw.bodyBase64 ?: "", "base64" );
		var charset   = arguments.raw.bodyCharset ?: ( settings.defaultCharset ?: "utf-8" );

		var text = "";
		try {
			text = charsetEncode( bodyBytes, charset );
		} catch ( any e ) {
			// The site named a character set we cannot decode with; fall back to UTF-8.
			text    = charsetEncode( bodyBytes, "utf-8" );
			charset = "utf-8";
		}

		// A case-insensitive convenience view of the headers. Last value wins for
		// duplicates; rawHeaders keeps every header line, including multiple Set-Cookie.
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
			"executionTime"       : getTickCount() - arguments.started,
			"errorDetail"         : ""
		};
	}

	/**
	 * Build the ok=false result for an operational failure, or throw when the request
	 * asked for exceptions.
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
			"fileContentAsBinary" : "",
			"charset"             : settings.defaultCharset ?: "utf-8",
			"finalUrl"            : "",
			"engineUsed"          : "",
			"executionTime"       : getTickCount() - arguments.started,
			"errorDetail"         : arguments.detail
		};
	}

	/**
	 * Run the given function inside a lock when a cookie file is in use, so two requests
	 * to the same site cannot corrupt that site's cookie file. Different sites are not
	 * locked against each other, so they still run at the same time.
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
			return false; // no limit configured
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
	 * Write a UTF-8 file with no byte-order mark. Uses a Java stream so the behavior is
	 * identical on Lucee, Adobe ColdFusion, and BoxLang (Adobe's FileWrite does not take a
	 * character-set argument).
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
			// A leftover temp file is swept later; record it only for debugging.
			logger.debug( "cbcloudscraper could not delete temp file '" & arguments.path & "': " & e.message );
		}
	}

	private string function extractDomain( required string url ){
		var host = reReplaceNoCase( arguments.url, "^https?://", "", "one" );
		host     = listFirst( host, "/" );
		host     = listFirst( host, "?" );
		// Drop any userinfo prefix and any port suffix.
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
	 * Read a key from a struct, returning a fallback when the key is absent. This avoids
	 * relying on engine-specific behavior of the ?: operator for missing struct keys.
	 */
	private any function opt(
		required struct options,
		required string key,
		any fallback
	){
		if ( structKeyExists( arguments.options, arguments.key ) ) {
			return arguments.options[ arguments.key ];
		}
		return arguments.fallback ?: "";
	}

}
