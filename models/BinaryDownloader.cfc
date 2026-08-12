/**
 * Downloads and stores the cbcloudscraper executable.
 *
 * This component does not use ColdBox state, WireBox state, or module settings. BinaryProvisioner
 * uses BinaryDownloader inside the application. tasks/Binary.cfc uses BinaryDownloader from
 * CommandBox. Each caller passes all required values as arguments.
 *
 * The executable is stored at baseDir/platform/cbcloudscraper[.exe]. A file named
 * .cbcloudscraper-version is stored in the same directory. The version file records the downloaded
 * release tag. Later requests use the tag to decide whether the cached executable is current.
 */
component singleton accessors="true" {

	variables.stampFileName  = ".cbcloudscraper-version";
	variables.defaultBaseURL = "https://github.com/homestar9/cbcloudscraper/releases/download";

	/**
	 * Return the directory, executable, and release asset names for the current operating system.
	 */
	struct function getPlatform(){
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
	 * Return the executable's full path inside baseDir.
	 *
	 * @baseDir The directory that holds the per-platform subfolders.
	 */
	string function binaryPathFor( required string baseDir ){
		var platform = getPlatform();
		return normalizeSlashes( arguments.baseDir ) & "/" & platform.dir & "/" & platform.exe;
	}

	/**
	 * Return true when the executable exists inside baseDir.
	 *
	 * @baseDir The directory that holds the per-platform subfolders.
	 */
	boolean function isPresent( required string baseDir ){
		return fileExists( binaryPathFor( arguments.baseDir ) );
	}

	/**
	 * Return the cached executable's release tag. Return an empty string when no tag is stored.
	 *
	 * @baseDir The directory that holds the per-platform subfolders.
	 */
	string function installedTag( required string baseDir ){
		var stampPath = stampPathFor( arguments.baseDir );
		if ( !fileExists( stampPath ) ) {
			return "";
		}
		try {
			return trim( fileRead( stampPath, "utf-8" ) );
		} catch ( any e ) {
			return "";
		}
	}

	/**
	 * Return true when the cached executable can be used for the requested tag.
	 *
	 * An executable is current when the file exists and its stored tag matches the requested tag.
	 * An executable without a stored tag is also current because it may be a local build from
	 * build-binary.ps1. A different stored tag means the cached executable must be replaced.
	 *
	 * @baseDir The directory that holds the per-platform subfolders.
	 * @tag     The requested release tag, for example "v1.0.0".
	 */
	boolean function isCurrent( required string baseDir, required string tag ){
		if ( !isPresent( arguments.baseDir ) ) {
			return false;
		}
		var stamp = installedTag( arguments.baseDir );
		return !len( stamp ) || stamp == arguments.tag;
	}

	/**
	 * Return a current executable. Download the requested release when the cache cannot be used.
	 *
	 * @baseDir        The directory that holds the per-platform subfolders.
	 * @tag            The requested release tag, for example "v1.0.0".
	 * @baseURL        The GitHub Releases base URL, such as ".../releases/download".
	 * @verifyChecksum Verify the download's SHA-256 before using it.
	 * @force          Download even when the cache already matches.
	 * @log            Optional callback function( message ) for progress output.
	 *
	 * @return A struct with action, path, tag, and present values.
	 */
	struct function ensure(
		required string baseDir,
		required string tag,
		required string baseURL,
		boolean verifyChecksum = true,
		boolean force          = false,
		any log                = ""
	){
		var platform   = getPlatform();
		var targetDir  = normalizeSlashes( arguments.baseDir ) & "/" & platform.dir;
		var binaryFile = targetDir & "/" & platform.exe;

		if ( !arguments.force && isCurrent( arguments.baseDir, arguments.tag ) ) {
			return {
				"action"  : "cached",
				"path"    : binaryFile,
				"tag"     : arguments.tag,
				"present" : true
			};
		}

		writeLog(
			arguments.log,
			"Downloading cbcloudscraper binary " & arguments.tag & " (" & platform.asset & ")..."
		);
		download(
			platform,
			targetDir,
			binaryFile,
			arguments.tag,
			arguments.baseURL,
			arguments.verifyChecksum
		);
		writeStamp( targetDir, arguments.tag );
		writeLog( arguments.log, "cbcloudscraper binary ready: " & binaryFile );

		return {
			"action"  : ( isPresent( arguments.baseDir ) && arguments.force ? "reinstalled" : "installed" ),
			"path"    : binaryFile,
			"tag"     : arguments.tag,
			"present" : true
		};
	}

	/**
	 * Read the module version from box.json. Return "0.0.0" when the file or version cannot be read.
	 *
	 * @moduleRoot The module directory that contains box.json.
	 */
	string function readModuleVersion( required string moduleRoot ){
		try {
			var box = deserializeJSON(
				fileRead( normalizeSlashes( arguments.moduleRoot ) & "/box.json", "utf-8" )
			);
			return box.version ?: "0.0.0";
		} catch ( any e ) {
			return "0.0.0";
		}
	}

	/**
	 * Return the release tag override. If no override is set, return "v" plus the module version.
	 *
	 * @moduleRoot The module's root folder.
	 * @override   A specific tag. Leave empty to build the tag from the module version.
	 */
	string function resolveTag( required string moduleRoot, string override = "" ){
		if ( len( trim( arguments.override ) ) ) {
			return trim( arguments.override );
		}
		return "v" & readModuleVersion( arguments.moduleRoot );
	}

	/**
	 * Return the GitHub Releases base URL. Use the override when it is set. Otherwise, build the
	 * URL from repository.url in box.json so the application and CommandBox task use the same URL.
	 *
	 * @moduleRoot The module's root folder.
	 * @override   A specific base URL. Leave empty to build it from box.json.
	 */
	string function deriveBaseURL( required string moduleRoot, string override = "" ){
		if ( len( trim( arguments.override ) ) ) {
			return reReplace( trim( arguments.override ), "/$", "" );
		}
		var repoURL = "";
		try {
			var box = deserializeJSON(
				fileRead( normalizeSlashes( arguments.moduleRoot ) & "/box.json", "utf-8" )
			);
			if ( structKeyExists( box, "repository" ) ) {
				repoURL = isStruct( box.repository ) ? ( box.repository.url ?: "" ) : box.repository;
			}
		} catch ( any e ) {
			repoURL = "";
		}
		if ( !len( repoURL ) ) {
			return variables.defaultBaseURL;
		}
		// Remove an optional .git suffix and trailing slash before adding /releases/download.
		repoURL = reReplace( repoURL, "\.git$", "" );
		repoURL = reReplace( repoURL, "/$", "" );
		return repoURL & "/releases/download";
	}

	// Private helpers

	/**
	 * Download and verify the release archive in a temporary directory. Replace the platform
	 * directory only after the download succeeds. A failed download leaves the cached files alone.
	 */
	private void function download(
		required struct platform,
		required string targetDir,
		required string binaryFile,
		required string tag,
		required string baseURL,
		required boolean verifyChecksum
	){
		var zipURL   = reReplace( arguments.baseURL, "/$", "" ) & "/" & arguments.tag & "/" & arguments.platform.asset;
		var stageDir = normalizeSlashes( getTempDirectory() ) & "/cbcloudscraper-download";
		var zipPath  = stageDir & "/" & arguments.platform.asset;

		if ( !directoryExists( stageDir ) ) {
			directoryCreate( stageDir, true, true );
		}

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

		if ( arguments.verifyChecksum ) {
			verifyChecksum( zipURL, zipPath );
		}

		// Replace the whole platform directory so files from older builds are removed.
		if ( directoryExists( arguments.targetDir ) ) {
			directoryDelete( arguments.targetDir, true );
		}
		directoryCreate( arguments.targetDir, true, true );
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

		if ( arguments.platform.dir != "win64" ) {
			createObject( "java", "java.io.File" )
				.init( arguments.binaryFile )
				.setExecutable( javacast( "boolean", true ), javacast( "boolean", false ) );
		}

		try {
			fileDelete( zipPath );
		} catch ( any e ) {
			// A later temporary-file cleanup can remove this archive.
		}
	}

	/**
	 * Compare the archive with its published .sha256 checksum. Skip this check when the checksum
	 * file is missing. Reject the archive when a published checksum does not match.
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
				// Support checksum files that contain only the hash or the hash followed by a filename.
				expected = lCase(
					trim(
						listFirst( trim( local.sumResult.fileContent ), " " & chr( 9 ) & chr( 10 ) & chr( 13 ) )
					)
				);
			}
		} catch ( any e ) {
			expected = "";
		}

		if ( !len( expected ) ) {
			return;
		}

		var actual = lCase( hash( fileReadBinary( arguments.zipPath ), "SHA-256" ) );
		if ( actual != expected ) {
			fileDelete( arguments.zipPath );
			throw(
				type    = "cbcloudscraper.BinaryUnavailable",
				message = "The downloaded cbcloudscraper binary failed its checksum check.",
				detail  = "Expected SHA-256 " & expected & " but got " & actual & ". The download was deleted. This can mean a corrupted or tampered file."
			);
		}
	}

	private string function stampPathFor( required string baseDir ){
		var platform = getPlatform();
		return normalizeSlashes( arguments.baseDir ) & "/" & platform.dir & "/" & variables.stampFileName;
	}

	private void function writeStamp( required string targetDir, required string tag ){
		fileWrite( normalizeSlashes( arguments.targetDir ) & "/" & variables.stampFileName, arguments.tag );
	}

	private string function manualInstructions( required struct platform, required string binaryFile ){
		return "To install it by hand, download " & arguments.platform.asset & " from the module's GitHub Releases and unzip it into '" &
		getDirectoryFromPath( arguments.binaryFile ) & "', or set the 'binaryPath' module setting to an executable you provide.";
	}

	private string function normalizeSlashes( required string path ){
		return reReplace(
			replace( arguments.path, "\", "/", "all" ),
			"/$",
			""
		);
	}

	private void function writeLog( any log, required string message ){
		if ( !isSimpleValue( arguments.log ) && isCustomFunction( arguments.log ) ) {
			arguments.log( arguments.message );
		}
	}

}
