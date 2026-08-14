/**
 * Adds Cloudflare-aware HTTP requests to ColdBox applications.
 * Copyright 2026 Angry Sam Productions, Inc. Licensed under the Apache License, Version 2.0.
 */
component {

	// Basic module information
	this.title       = "cbcloudscraper";
	this.author      = "Angry Sam Productions, Inc.";
	this.webURL      = "https://github.com/homestar9/cbcloudscraper";
	this.description = "Make HTTP requests through Cloudflare protection in ColdBox using cloudscraper and curl_cffi.";
	this.version     = "@build.version@+@build.number@";

	// WireBox namespace for this module's models
	this.modelNamespace = "cbcloudscraper";

	// CFML mapping for this module
	this.cfmapping = "cbcloudscraper";

	// This module does not depend on other ColdBox modules.
	this.dependencies = [];

	/**
	 * Set the module's default options.
	 *
	 * An application can override these options in moduleSettings.cbcloudscraper inside
	 * config/ColdBox.cfc. BinaryProvisioner finds or downloads the executable on the first request.
	 */
	function configure(){
		var tmpRoot        = createObject( "java", "java.lang.System" ).getProperty( "java.io.tmpdir" );
		var defaultWorkDir = reReplace( tmpRoot, "[\\/]$", "" ) & "/cbcloudscraper";

		settings = {
			// Binary setup
			// Git does not store the executable. The module downloads it from GitHub Releases
			// on the first request and then caches it. Set binaryPath to use your own executable.
			// A custom path is useful on a server that cannot download files from the internet.
			"binaryPath"             : "", // Leave empty to find or download the executable.
			"binaryDirectory"        : "", // Leave empty to use this module's bin directory.
			"autoDownloadBinary"     : true, // Set false when you provide the executable yourself.
			"binaryBaseURL"          : "", // Leave empty to use repository.url from box.json.
			"binaryReleaseTag"       : "", // Leave empty to use "v" plus the module version.
			"verifyChecksum"         : true,
			// Fail the download when the published .sha256 file cannot be read. The default warns
			// and installs the executable anyway, which keeps things working if that file is ever
			// missing from a release. Set this true when an unchecked executable is not acceptable.
			"strictChecksum"         : false,
			// Request defaults
			"defaultTimeout"         : 30, // Maximum request time in seconds.
			// Use this timeout when downloadTo is set and the request has no timeout.
			// File downloads may take longer than page requests.
			"defaultDownloadTimeout" : 300,
			// By default, save only 2xx responses. This protects an existing file from error responses.
			"downloadOnlyOn2xx"      : true,
			"defaultEngine"          : "auto", // Valid values: auto, curl_cffi, or cloudscraper.
			"impersonate"            : "chrome", // Browser profile used by curl_cffi.
			"followRedirects"        : true,
			"verifySSL"              : true,
			"defaultHeaders"         : {},
			"defaultCharset"         : "utf-8", // Used when the response does not name a character set.
			"proxy"                  : "", // Leave empty to connect without a proxy.
			// Temporary files
			"workingDirectory"       : defaultWorkDir,
			"keepFailureLogs"        : false, // Keep the diagnostic log after a failed request.
			"tempSweepMinutes"       : 30, // Delete temporary files older than this many minutes.
			// Cookie storage
			"cookieCache"            : { "enabled" : false, "directory" : "" },
			// Process limits
			"maxConcurrentProcesses" : 8, // Set 0 to allow any number of processes.
			"acquireTimeout"         : 20, // Seconds to wait for an open process slot.
			"throwOnError"           : false
		};
	}

	/**
	 * Create the directories that the module needs when ColdBox loads the module.
	 *
	 * This method does not check the executable. BinaryProvisioner checks it on the first request.
	 */
	function onLoad(){
		makeDirectory( settings.workingDirectory );

		var configuredCookieDir = ( settings.cookieCache.directory ?: "" );
		var cookieDir           = len( configuredCookieDir ) ? configuredCookieDir : ( settings.workingDirectory & "/cookies" );
		if ( settings.cookieCache.enabled ?: false ) {
			makeDirectory( cookieDir );
		}
		// BinaryProvisioner checks the executable on the first request.
	}

	/**
	 * Create a directory and any missing parents. java.io.File.mkdirs() is used instead of
	 * directoryCreate() because Adobe ColdFusion accepts only the path argument, and Lucee's
	 * extra arguments make the file fail to compile on Adobe - even on a line that never runs.
	 */
	private boolean function makeDirectory( required string path ){
		if ( directoryExists( arguments.path ) ) {
			return true;
		}
		return createObject( "java", "java.io.File" ).init( javacast( "string", arguments.path ) ).mkdirs();
	}

	/**
	 * Handle module shutdown.
	 *
	 * No cleanup is needed because each request uses a short-lived process.
	 */
	function onUnload(){
	}

}
