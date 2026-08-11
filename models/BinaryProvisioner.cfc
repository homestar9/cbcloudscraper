/**
 * Makes sure the cbcloudscraper executable is present, downloading it if needed.
 *
 * The binary is not stored in the git repository. It is published as a per-platform asset
 * on the module's GitHub Releases. The first time a request runs, this component checks
 * for the binary and, if it is missing, downloads the build that matches the current
 * operating system, verifies its checksum, and unpacks it. Every later request finds the
 * binary already in place and returns immediately. This is the same approach the
 * commandbox-cfformat module uses for its native helper.
 *
 * A host application can skip all of this by setting the "binaryPath" module setting to an
 * executable it placed itself (useful on servers with no outbound internet access).
 */
component singleton accessors="true" {

	property name="settings" inject="coldbox:moduleSettings:cbcloudscraper";
	property name="logger"   inject="logbox:logger:{this}";

	/**
	 * Return the absolute path to a ready-to-run executable, downloading it if necessary.
	 * Throws cbcloudscraper.BinaryUnavailable when the binary is missing and cannot be
	 * obtained (download turned off, no network, or a checksum mismatch).
	 */
	string function ensureBinary(){
		// 1. An explicit path always wins. The host placed the binary itself.
		var explicitPath = settings.binaryPath ?: "";
		if ( len( explicitPath ) ) {
			if ( fileExists( explicitPath ) ) {
				return explicitPath;
			}
			throw(
				type    = "cbcloudscraper.BinaryUnavailable",
				message = "The configured binaryPath does not exist.",
				detail  = "binaryPath is set to '" & explicitPath & "' but no file is there. Point it at the cbcloudscraper executable, or clear binaryPath to let the module download one."
			);
		}

		var platform   = getPlatform();
		var targetDir  = getBinaryDirectory() & "/" & platform.dir;
		var binaryFile = targetDir & "/" & platform.exe;

		// 2. Already present (a prior download, or a local build during development).
		if ( fileExists( binaryFile ) ) {
			return binaryFile;
		}

		// 3. Not present. Either download it or fail with clear instructions.
		if ( !( settings.autoDownloadBinary ?: true ) ) {
			throw(
				type    = "cbcloudscraper.BinaryUnavailable",
				message = "The cbcloudscraper binary is missing and automatic download is turned off.",
				detail  = manualInstructions( platform, binaryFile )
			);
		}

		// One request at a time may download; the rest wait and then find the file present.
		lock name="cbcloudscraper-binary-#platform.dir#" type="exclusive" timeout="300" {
			if ( fileExists( binaryFile ) ) {
				return binaryFile;
			}
			downloadBinary( platform, targetDir, binaryFile );
		}

		return binaryFile;
	}

	/************************* PRIVATE HELPERS *************************/

	/**
	 * Download the platform's release asset, verify its checksum, and unpack it so that
	 * binaryFile exists afterward. Throws cbcloudscraper.BinaryUnavailable on any failure.
	 */
	private void function downloadBinary(
		required struct platform,
		required string targetDir,
		required string binaryFile
	){
		var tag      = getReleaseTag();
		var baseURL  = reReplace( settings.binaryBaseURL, "/$", "" );
		var zipURL   = baseURL & "/" & tag & "/" & arguments.platform.asset;
		var stageDir = ( settings.workingDirectory ?: getTempDirectory() ) & "/binary-download";
		var zipPath  = stageDir & "/" & arguments.platform.asset;

		if ( !directoryExists( stageDir ) ) {
			directoryCreate( stageDir, true, true );
		}

		logger.info( "cbcloudscraper downloading binary from " & zipURL );

		// Download the zip to disk.
		try {
			cfhttp(
				url         = zipURL,
				method      = "GET",
				getAsBinary = "yes",
				path        = stageDir,
				file        = arguments.platform.asset,
				timeout     = 180,
				result      = "local.httpResult"
			);
		} catch ( any e ) {
			throw(
				type    = "cbcloudscraper.BinaryUnavailable",
				message = "Could not download the cbcloudscraper binary.",
				detail  = "Downloading " & zipURL & " failed: " & e.message & ". " & manualInstructions(
					arguments.platform,
					arguments.binaryFile
				)
			);
		}

		if ( ( local.httpResult.status_code ?: 0 ) != 200 || !fileExists( zipPath ) ) {
			throw(
				type    = "cbcloudscraper.BinaryUnavailable",
				message = "Could not download the cbcloudscraper binary.",
				detail  = "Requesting " & zipURL & " returned status " & ( local.httpResult.status_code ?: "unknown" ) & ". " & manualInstructions(
					arguments.platform,
					arguments.binaryFile
				)
			);
		}

		// Verify the checksum unless turned off.
		if ( settings.verifyChecksum ?: true ) {
			verifyChecksum( zipURL, zipPath );
		}

		// Unpack into the platform directory.
		if ( !directoryExists( arguments.targetDir ) ) {
			directoryCreate( arguments.targetDir, true, true );
		}
		cfzip(
			action      = "unzip",
			file        = zipPath,
			destination = arguments.targetDir,
			overwrite   = true
		);

		if ( !fileExists( arguments.binaryFile ) ) {
			throw(
				type    = "cbcloudscraper.BinaryUnavailable",
				message = "The downloaded archive did not contain the expected executable.",
				detail  = "Expected '" & arguments.binaryFile & "' after unpacking " & arguments.platform.asset & ". " & manualInstructions(
					arguments.platform,
					arguments.binaryFile
				)
			);
		}

		// On non-Windows systems the file needs the executable bit set.
		if ( arguments.platform.dir != "win64" ) {
			createObject( "java", "java.io.File" )
				.init( arguments.binaryFile )
				.setExecutable( javacast( "boolean", true ), javacast( "boolean", false ) );
		}

		// Clean up the downloaded archive.
		try {
			fileDelete( zipPath );
		} catch ( any e ) {
			logger.debug( "cbcloudscraper could not delete '" & zipPath & "': " & e.message );
		}

		logger.info( "cbcloudscraper binary ready at " & arguments.binaryFile );
	}

	/**
	 * Download the ".sha256" companion file and compare it with the archive's hash.
	 */
	private void function verifyChecksum( required string zipURL, required string zipPath ){
		var sumURL   = arguments.zipURL & ".sha256";
		var expected = "";
		try {
			cfhttp(
				url     = sumURL,
				method  = "GET",
				timeout = 60,
				result  = "local.sumResult"
			);
			if ( ( local.sumResult.status_code ?: 0 ) == 200 ) {
				// The file may be "<hash>" or "<hash>  <filename>"; take the first token.
				expected = lCase(
					trim(
						listFirst( trim( local.sumResult.fileContent ), " " & chr( 9 ) & chr( 10 ) & chr( 13 ) )
					)
				);
			}
		} catch ( any e ) {
			logger.debug( "cbcloudscraper checksum file fetch failed: " & e.message );
		}

		// No checksum published: skip rather than block (verifyChecksum stays best-effort
		// when the .sha256 asset is absent, but a present-and-wrong checksum always fails).
		if ( !len( expected ) ) {
			logger.warn( "cbcloudscraper: no checksum found at " & sumURL & "; skipping verification." );
			return;
		}

		var actual = lCase( hash( fileReadBinary( arguments.zipPath ), "SHA-256" ) );
		if ( actual != expected ) {
			fileDelete( arguments.zipPath );
			throw(
				type    = "cbcloudscraper.BinaryUnavailable",
				message = "The downloaded cbcloudscraper binary failed its checksum check.",
				detail  = "Expected SHA-256 " & expected & " but got " & actual & " for " & arguments.zipPath & ". The download was deleted. This can mean a corrupted or tampered file."
			);
		}
	}

	/**
	 * Return the GitHub Release tag to download from: the configured tag, or "v" plus the
	 * module's own version read from its box.json.
	 */
	private string function getReleaseTag(){
		var configured = settings.binaryReleaseTag ?: "";
		if ( len( configured ) ) {
			return configured;
		}
		var version = "1.0.0";
		try {
			version = deserializeJSON( fileRead( expandPath( "/cbcloudscraper/box.json" ), "utf-8" ) ).version;
		} catch ( any e ) {
			logger.debug( "cbcloudscraper could not read box.json version: " & e.message );
		}
		return "v" & version;
	}

	/**
	 * Return where downloaded binaries are stored: the configured directory, or the
	 * module's own bin folder.
	 */
	private string function getBinaryDirectory(){
		var configured = settings.binaryDirectory ?: "";
		if ( len( configured ) ) {
			return reReplace( configured, "[\\/]$", "" );
		}
		return reReplace(
			expandPath( "/cbcloudscraper/bin" ),
			"[\\/]$",
			""
		);
	}

	/**
	 * Decide the platform folder, executable name, and release asset name for this OS.
	 */
	private struct function getPlatform(){
		var osName = server.os.name;
		if ( findNoCase( "Windows", osName ) ) {
			return {
				"dir"   : "win64",
				"exe"   : "cbcloudscraper.exe",
				"asset" : "cbcloudscraper-win64.zip"
			};
		}
		if ( findNoCase( "Mac", osName ) || findNoCase( "Darwin", osName ) ) {
			return {
				"dir"   : "mac",
				"exe"   : "cbcloudscraper",
				"asset" : "cbcloudscraper-mac.zip"
			};
		}
		return {
			"dir"   : "linux64",
			"exe"   : "cbcloudscraper",
			"asset" : "cbcloudscraper-linux64.zip"
		};
	}

	/**
	 * A message telling a person how to place the binary by hand when download is not an
	 * option (for example on a server with no outbound internet access).
	 */
	private string function manualInstructions( required struct platform, required string binaryFile ){
		return "To install it by hand, download " & arguments.platform.asset & " from the module's GitHub Releases, unzip it to '" &
		getDirectoryFromPath( arguments.binaryFile ) & "', or set the 'binaryPath' module setting to an executable you provide.";
	}

}
