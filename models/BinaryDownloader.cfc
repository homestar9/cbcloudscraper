/**
 * Reusable download logic for the cbcloudscraper executable.
 *
 * This component holds no ColdBox or WireBox state and reads no module settings, so the same
 * code runs in two places: inside a running ColdBox app (used by BinaryProvisioner) and inside
 * a CommandBox task (tasks/Binary.cfc). Every input is passed in as an argument.
 *
 * The binary for a given module version lives at:  <basedir>/<platform>/cbcloudscraper[.exe]
 * A marker file  <basedir>/<platform>/.cbcloudscraper-version  records the release tag that was
 * downloaded, so a later run can tell whether the cached binary matches the wanted version and
 * refresh it when the module has been updated.
 */
component singleton accessors="true" {

	variables.stampFileName  = ".cbcloudscraper-version";
	variables.defaultBaseURL = "https://github.com/homestar9/cbcloudscraper/releases/download";

	/**
	 * Decide the platform folder, executable name, and release asset name for this OS.
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
	 * The absolute path where the executable for this platform belongs under baseDir.
	 *
	 * @baseDir The directory that holds the per-platform subfolders.
	 */
	string function binaryPathFor( required string baseDir ){
		var platform = getPlatform();
		return normalizeSlashes( arguments.baseDir ) & "/" & platform.dir & "/" & platform.exe;
	}

	/**
	 * True when the executable for this platform exists under baseDir.
	 *
	 * @baseDir The directory that holds the per-platform subfolders.
	 */
	boolean function isPresent( required string baseDir ){
		return fileExists( binaryPathFor( arguments.baseDir ) );
	}

	/**
	 * The release tag recorded for the cached binary, or an empty string when there is none.
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
	 * True when the cached binary can be used for the wanted tag.
	 *
	 * A binary counts as current when it exists AND either it carries no version stamp (a local
	 * build made with build-binary.ps1) or its stamp matches the wanted tag. Only a stamp that
	 * names a *different* tag is treated as stale, which is what triggers a refresh after the
	 * module has been updated to a new version.
	 *
	 * @baseDir The directory that holds the per-platform subfolders.
	 * @tag     The wanted release tag, for example "v1.0.0".
	 */
	boolean function isCurrent( required string baseDir, required string tag ){
		if ( !isPresent( arguments.baseDir ) ) {
			return false;
		}
		var stamp = installedTag( arguments.baseDir );
		return !len( stamp ) || stamp == arguments.tag;
	}

	/**
	 * Make sure the cached binary matches the wanted tag, downloading it when needed.
	 *
	 * @baseDir        The directory that holds the per-platform subfolders.
	 * @tag            The wanted release tag, for example "v1.0.0".
	 * @baseURL        The GitHub Releases download base, for example ".../releases/download".
	 * @verifyChecksum Verify the download's SHA-256 before using it.
	 * @force          Download even when the cache already matches.
	 * @log            Optional callback function( message ) for progress output.
	 *
	 * @return struct { action:"cached"|"installed"|"reinstalled", path, tag, present:true }
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
	 * The module version read from a box.json at moduleRoot, or "0.0.0" when it cannot be read.
	 *
	 * @moduleRoot The module's root folder (the one holding box.json).
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
	 * The release tag to fetch: the override when given, otherwise "v" + the module version.
	 *
	 * @moduleRoot The module's root folder.
	 * @override   A tag to force, or empty to derive from the version.
	 */
	string function resolveTag( required string moduleRoot, string override = "" ){
		if ( len( trim( arguments.override ) ) ) {
			return trim( arguments.override );
		}
		return "v" & readModuleVersion( arguments.moduleRoot );
	}

	/**
	 * The GitHub Releases download base URL. Uses the override when given, otherwise derives it
	 * from box.json's repository url so the app and the CLI task share one source of truth.
	 *
	 * @moduleRoot The module's root folder.
	 * @override   A base URL to force, or empty to derive from box.json.
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
		// Normalize "https://github.com/owner/repo(.git)(/)" -> ".../releases/download".
		repoURL = reReplace( repoURL, "\.git$", "" );
		repoURL = reReplace( repoURL, "/$", "" );
		return repoURL & "/releases/download";
	}

	/************************* PRIVATE HELPERS *************************/

	/**
	 * Download the platform's asset to a staging file, verify it, then replace the platform
	 * folder with its contents. The existing cache is only cleared after a good download, so a
	 * failed download leaves the previous binary in place.
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

		// Replace the platform folder so no stale files from an older build linger.
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
			// Best effort: a leftover staged zip in the temp folder is harmless.
		}
	}

	/**
	 * Download the ".sha256" companion file and compare it with the archive's hash. A published
	 * checksum that does not match always fails; a missing checksum file is skipped.
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
