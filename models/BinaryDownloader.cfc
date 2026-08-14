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
	 * @onProgress     Optional callback function( message ) for progress output.
	 * @strictChecksum Fail the download when the published checksum cannot be read. Only used when
	 *                 verifyChecksum is true.
	 * @onWarning      Optional callback function( message ) for warnings. Falls back to onProgress.
	 *
	 * @return A struct with action, path, tag, and present values.
	 */
	struct function ensure(
		required string baseDir,
		required string tag,
		required string baseURL,
		boolean verifyChecksum = true,
		boolean force          = false,
		any onProgress         = "",
		boolean strictChecksum = false,
		any onWarning          = ""
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

		logMessage(
			arguments.onProgress,
			"Downloading cbcloudscraper binary " & arguments.tag & " (" & platform.asset & ")..."
		);
		download(
			platform,
			targetDir,
			binaryFile,
			arguments.tag,
			arguments.baseURL,
			arguments.verifyChecksum,
			arguments.onProgress,
			arguments.strictChecksum,
			arguments.onWarning
		);
		writeStamp( targetDir, arguments.tag );
		logMessage( arguments.onProgress, "cbcloudscraper binary ready: " & binaryFile );

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
		required boolean verifyChecksum,
		any onProgress         = "",
		boolean strictChecksum = false,
		any onWarning          = ""
	){
		var zipURL   = reReplace( arguments.baseURL, "/$", "" ) & "/" & arguments.tag & "/" & arguments.platform.asset;
		var stageDir = normalizeSlashes( getTempDirectory() ) & "/cbcloudscraper-download";
		var zipPath  = stageDir & "/" & arguments.platform.asset;

		makeDirectory( stageDir );

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
			assertChecksum(
				zipURL,
				zipPath,
				arguments.onProgress,
				arguments.strictChecksum,
				arguments.onWarning
			);
		}

		// Replace the whole platform directory so files from older builds are removed.
		if ( directoryExists( arguments.targetDir ) ) {
			directoryDelete( arguments.targetDir, true );
		}
		makeDirectory( arguments.targetDir );
		unzip( zipPath, arguments.targetDir );

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
	 * Compare the archive with its published .sha256 checksum. Reject the archive when a published
	 * checksum does not match.
	 *
	 * When the checksum file cannot be read, the behavior depends on strictChecksum. The default is
	 * to warn and continue, which keeps a download working if the .sha256 asset is ever missing.
	 * With strictChecksum the download fails instead, so an application can require that every
	 * executable it runs was checked.
	 *
	 * The name is not "verifyChecksum" because ensure() and download() have a boolean argument
	 * with that name, and an unscoped call would resolve to the argument instead of this method.
	 */
	private void function assertChecksum(
		required string zipURL,
		required string zipPath,
		any onProgress         = "",
		boolean strictChecksum = false,
		any onWarning          = ""
	){
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
			if ( arguments.strictChecksum ) {
				fileDelete( arguments.zipPath );
				throw(
					type    = "cbcloudscraper.BinaryUnavailable",
					message = "The cbcloudscraper binary could not be checked against a published checksum.",
					detail  = "Could not read the SHA-256 checksum at " & sumURL & ". The download was deleted because the strictChecksum setting is on. Set strictChecksum to false to accept a download that could not be checked."
				);
			}
			warn(
				arguments.onWarning,
				arguments.onProgress,
				"Warning: could not read the published SHA-256 checksum at " & sumURL & ". Skipping checksum verification for this download."
			);
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

	/**
	 * Unpack a zip archive into a directory.
	 *
	 * java.util.zip is used instead of cfzip because cfzip is not available on a default Adobe
	 * ColdFusion install. Adobe ships that tag in a separate "zip" package that has to be added with
	 * cfpm, and Adobe rejects the whole file when it compiles it, not when the line runs. That made
	 * the module impossible to load at all, even for an application that already had the executable
	 * and never downloaded anything. This is the same reasoning that replaced directoryCreate() with
	 * java.io.File.mkdirs().
	 *
	 * @zipPath   The archive to read.
	 * @targetDir The directory to unpack into. It must already exist.
	 */
	private void function unzip( required string zipPath, required string targetDir ){
		var targetRoot = createObject( "java", "java.io.File" ).init( javacast( "string", arguments.targetDir ) );
		// getCanonicalPath() resolves "..", symbolic links, and separator differences, so it gives a
		// single spelling of the path that entry paths can be compared against.
		var rootPath = targetRoot.getCanonicalPath();
		var fileIn   = createObject( "java", "java.io.FileInputStream" ).init( javacast( "string", arguments.zipPath ) );
		var zipIn    = createObject( "java", "java.util.zip.ZipInputStream" ).init( fileIn );

		try {
			local.entry = zipIn.getNextEntry();
			while ( !isNull( local.entry ) ) {
				writeZipEntry( zipIn, local.entry, targetRoot, rootPath );
				zipIn.closeEntry();
				local.entry = zipIn.getNextEntry();
			}
		} finally {
			closeQuietly( zipIn );
			closeQuietly( fileIn );
		}
	}

	/**
	 * Write one zip entry to disk. Reject an entry that would land outside the target directory.
	 *
	 * @zipIn      The open ZipInputStream, positioned on this entry.
	 * @entry      The ZipEntry being read.
	 * @targetRoot A java.io.File for the target directory.
	 * @rootPath   The canonical path of the target directory.
	 */
	private void function writeZipEntry(
		required any zipIn,
		required any entry,
		required any targetRoot,
		required string rootPath
	){
		// The zip format says entry names use forward slashes, but PowerShell's Compress-Archive
		// writes backslashes on Windows, and releases up to 1.1.0 were built that way. Java decides
		// whether an entry is a directory by looking for a trailing forward slash, so without this
		// normalization a folder entry such as "_internal\cryptography\" is taken for a file. The
		// module then creates a file with that name, and every later entry inside that folder fails
		// because its parent directory cannot be created.
		var entryName = replace( arguments.entry.getName(), "\", "/", "all" );
		var isFolder  = arguments.entry.isDirectory() || right( entryName, 1 ) == "/";

		var outFile = createObject( "java", "java.io.File" ).init(
			arguments.targetRoot,
			javacast( "string", entryName )
		);
		var outPath = outFile.getCanonicalPath();

		// An archive can name a path outside the target, such as "../../evil.exe". cfzip refused
		// those entries for us, so this check has to replace it.
		var separator = createObject( "java", "java.io.File" ).separator;
		if ( outPath != arguments.rootPath && !outPath.startsWith( arguments.rootPath & separator ) ) {
			throw(
				type    = "cbcloudscraper.BinaryUnavailable",
				message = "The downloaded archive contains a file path outside the install directory.",
				detail  = "Entry '" & entryName & "' resolves to '" & outPath & "', which is not inside '" & arguments.rootPath & "'. The archive was rejected without unpacking it."
			);
		}

		if ( isFolder ) {
			assertDirectory( outPath, entryName );
			return;
		}

		assertDirectory( outFile.getParentFile().getCanonicalPath(), entryName );

		// Copy in pieces. The archive holds a 20 MB executable, and reading an entry into one CFML
		// variable would put the whole file in heap.
		var buffer = createObject( "java", "java.lang.reflect.Array" ).newInstance(
			createObject( "java", "java.lang.Byte" ).TYPE,
			javacast( "int", 65536 )
		);
		var fileOut = createObject( "java", "java.io.FileOutputStream" ).init( outFile );
		try {
			local.read = arguments.zipIn.read( buffer );
			while ( local.read > 0 ) {
				fileOut.write( buffer, javacast( "int", 0 ), javacast( "int", local.read ) );
				local.read = arguments.zipIn.read( buffer );
			}
		} finally {
			closeQuietly( fileOut );
		}
	}

	/**
	 * Create a directory while unpacking, and throw a readable error when that is not possible.
	 *
	 * Without this, a failure shows up later as a FileNotFoundException naming a path with no
	 * explanation of why the path is missing.
	 *
	 * @path      The directory to create.
	 * @entryName The archive entry being unpacked, used in the error message.
	 */
	private void function assertDirectory( required string path, required string entryName ){
		if ( makeDirectory( arguments.path ) ) {
			return;
		}
		throw(
			type    = "cbcloudscraper.BinaryUnavailable",
			message = "Could not create a directory while unpacking the cbcloudscraper archive.",
			detail  = "Unpacking entry '" & arguments.entryName & "' needs the directory '" & arguments.path & "', which could not be created. A file may already exist under that name, or the account running the server may not have write access there."
		);
	}

	/**
	 * Close a stream and ignore any error. A failure to close cannot be acted on, and throwing here
	 * would hide the real error that sent us into the finally block.
	 */
	private void function closeQuietly( any stream ){
		if ( isNull( arguments.stream ) ) {
			return;
		}
		try {
			arguments.stream.close();
		} catch ( any e ) {
			// Nothing useful to do with a close failure.
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

	/**
	 * Call the progress callback with a message. Do nothing when no callback was given.
	 *
	 * The name is not "writeLog" because that is a built-in CFML function, and Lucee resolves
	 * an unscoped call to the built-in instead of this method.
	 */
	private void function logMessage( any onProgress, required string message ){
		if ( isNull( arguments.onProgress ) || isSimpleValue( arguments.onProgress ) ) {
			return;
		}
		var callable = false;
		try {
			callable = isClosure( arguments.onProgress ) || isCustomFunction( arguments.onProgress );
		} catch ( any e ) {
			// Adobe ColdFusion's isCustomFunction can throw when the value is not a function.
			callable = false;
		}
		if ( callable ) {
			arguments.onProgress( arguments.message );
		}
	}

	/**
	 * Send a warning to the warning callback, or to the progress callback when there is no separate
	 * warning callback.
	 *
	 * This exists so a running application can record a warning at warn level. This component has no
	 * logger of its own, because tasks/Binary.cfc builds it outside WireBox, so the caller supplies
	 * the callback instead.
	 */
	private void function warn( any onWarning, any onProgress, required string message ){
		if ( !isNull( arguments.onWarning ) && !isSimpleValue( arguments.onWarning ) ) {
			logMessage( arguments.onWarning, arguments.message );
			return;
		}
		logMessage( arguments.onProgress, arguments.message );
	}

	/**
	 * Create a directory and any missing parents. java.io.File.mkdirs() is used instead of
	 * directoryCreate() because Adobe ColdFusion accepts only the path argument, and Lucee's
	 * extra arguments make the file fail to compile on Adobe - even on a line that never runs.
	 *
	 * FileUtil.cfc has the shared version of this method. CommandBox builds this component without
	 * WireBox, so FileUtil cannot be injected here. Keep this local version to avoid that dependency.
	 */
	private boolean function makeDirectory( required string path ){
		if ( directoryExists( arguments.path ) ) {
			return true;
		}
		return createObject( "java", "java.io.File" ).init( javacast( "string", arguments.path ) ).mkdirs();
	}

}
