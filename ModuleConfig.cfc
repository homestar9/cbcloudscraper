/**
 * cbcloudscraper — make HTTP requests through Cloudflare protection in ColdBox.
 * Copyright 2026 Angry Sam Productions, Inc.. Licensed under the Apache License, Version 2.0.
 */
component {

	// Module Properties
	this.title       = "cbcloudscraper";
	this.author      = "Angry Sam Productions, Inc.";
	this.webURL      = "https://github.com/homestar9/cbcloudscraper";
	this.description = "Make HTTP requests through Cloudflare protection in ColdBox using cloudscraper and curl_cffi.";
	this.version     = "@build.version@+@build.number@";

	// Model Namespace
	this.modelNamespace = "cbcloudscraper";

	// CF Mapping
	this.cfmapping = "cbcloudscraper";

	// Dependencies
	this.dependencies = [];

	/**
	 * Configure Module.
	 *
	 * Sets the module's default settings. A host application can override any of these through
	 * moduleSettings.cbcloudscraper in its own config/ColdBox.cfc. The executable itself is
	 * resolved and downloaded on first use by BinaryProvisioner.
	 */
	function configure(){
		var tmpRoot        = createObject( "java", "java.lang.System" ).getProperty( "java.io.tmpdir" );
		var defaultWorkDir = reReplace( tmpRoot, "[\\/]$", "" ) & "/cbcloudscraper";

		settings = {
			// ── Binary provisioning ────────────────────────────────────────────────
			// The executable is not stored in git. It is downloaded from GitHub Releases on
			// first use and cached. Set binaryPath to skip that and use an executable you
			// placed yourself (for example on a server with no outbound internet access).
			"binaryPath"             : "", // "" = auto-resolve and download when missing
			"binaryDirectory"        : "", // "" = the module's own bin/ folder
			"autoDownloadBinary"     : true, // false = require a pre-placed binary
			"binaryBaseURL"          : "", // "" = derive from box.json repository.url
			"binaryReleaseTag"       : "", // "" = derive "v" + the module version
			"verifyChecksum"         : true,
			// ── Request defaults ───────────────────────────────────────────────────
			"defaultTimeout"         : 30, // seconds
			"engineOrder"            : [ "curl_cffi", "cloudscraper" ], // order tried in "auto"
			"defaultEngine"          : "auto", // auto | curl_cffi | cloudscraper
			"impersonate"            : "chrome", // curl_cffi browser profile
			"followRedirects"        : true,
			"verifySSL"              : true,
			"defaultHeaders"         : {},
			"defaultCharset"         : "utf-8", // fallback when the site does not name one
			"proxy"                  : "", // "" = no proxy
			// ── Temp files ─────────────────────────────────────────────────────────
			"workingDirectory"       : defaultWorkDir,
			"keepFailureLogs"        : false, // keep the diagnostic log on failure
			"tempSweepMinutes"       : 30, // remove temp files older than this
			// ── Cookie storage ─────────────────────────────────────────────────────
			"cookieCache"            : { "enabled" : false, "directory" : "" },
			// ── Concurrency ────────────────────────────────────────────────────────
			"maxConcurrentProcesses" : 8, // 0 = no limit
			"acquireTimeout"         : 20, // seconds to wait for a free slot
			"throwOnError"           : false
		};
	}

	/**
	 * Fired when the module is registered and activated. Creates the directories the module
	 * writes to. The executable is resolved and downloaded on first use, so nothing about it
	 * is checked here.
	 */
	function onLoad(){
		if ( !directoryExists( settings.workingDirectory ) ) {
			directoryCreate( settings.workingDirectory, true, true );
		}

		var configuredCookieDir = ( settings.cookieCache.directory ?: "" );
		var cookieDir           = len( configuredCookieDir ) ? configuredCookieDir : ( settings.workingDirectory & "/cookies" );
		if ( ( settings.cookieCache.enabled ?: false ) && !directoryExists( cookieDir ) ) {
			directoryCreate( cookieDir, true, true );
		}
		// The executable is resolved and downloaded on first use by BinaryProvisioner, so
		// there is nothing to check here at load time.
	}

	/**
	 * Fired when the module is unregistered and unloaded. Nothing to tear down: each
	 * request runs its own short-lived process, so there is no background service.
	 */
	function onUnload(){
	}

}
