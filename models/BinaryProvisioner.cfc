/**
 * Makes sure the cbcloudscraper executable is present, downloading it if needed.
 *
 * The binary is not stored in the git repository. It is published as a per-platform asset on
 * the module's GitHub Releases. The first time a request runs, this component checks for the
 * binary and, if it is missing or is for a different module version, downloads the build that
 * matches the current operating system, verifies its checksum, and unpacks it. Every later
 * request finds the correct binary already in place and returns immediately. This follows the
 * approach the commandbox-cfformat module uses for its native helper.
 *
 * The download itself lives in BinaryDownloader, a plain component shared with the CommandBox
 * task (tasks/Binary.cfc) so the app and the CLI behave identically.
 *
 * A host application can skip all of this by setting the "binaryPath" module setting to an
 * executable it placed itself (useful on servers with no outbound internet access).
 */
component singleton accessors="true" {

	property name="settings"   inject="coldbox:moduleSettings:cbcloudscraper";
	property name="downloader" inject="BinaryDownloader@cbcloudscraper";
	property name="logger"     inject="logbox:logger:{this}";

	/**
	 * Return the absolute path to a ready-to-run executable, downloading it if necessary.
	 * Throws cbcloudscraper.BinaryUnavailable when the binary is missing or out of date and
	 * cannot be obtained (download turned off, no network, or a checksum mismatch).
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

		var baseDir = getBinaryDirectory();
		var tag     = getReleaseTag();

		// 2. The correct version is already present (a prior download, or a local dev build).
		if ( downloader.isCurrent( baseDir, tag ) ) {
			return downloader.binaryPathFor( baseDir );
		}

		// 3. Not current. Either download it or fail with a clear message.
		if ( !( settings.autoDownloadBinary ?: true ) ) {
			throw(
				type    = "cbcloudscraper.BinaryUnavailable",
				message = missingMessage( baseDir, tag ),
				detail  = "Automatic download is turned off (autoDownloadBinary=false). " & manualInstructions(
					baseDir
				)
			);
		}

		// One request at a time downloads; the rest wait and then find the file in place.
		lock name="cbcloudscraper-binary-#hash( baseDir, "MD5" )#" type="exclusive" timeout="300" {
			if ( downloader.isCurrent( baseDir, tag ) ) {
				return downloader.binaryPathFor( baseDir );
			}
			downloader.ensure(
				baseDir        = baseDir,
				tag            = tag,
				baseURL        = getBaseURL(),
				verifyChecksum = ( settings.verifyChecksum ?: true ),
				force          = false,
				log            = logCallback()
			);
		}

		return downloader.binaryPathFor( baseDir );
	}

	/**
	 * Download the binary for the current module version, replacing any cached copy. Used by the
	 * CommandBox task and available to app code that wants to pre-install at startup.
	 *
	 * @force Download even when the cache already matches the wanted version.
	 *
	 * @return The BinaryDownloader result struct { action, path, tag, present }.
	 */
	struct function install( boolean force = true ){
		return downloader.ensure(
			baseDir        = getBinaryDirectory(),
			tag            = getReleaseTag(),
			baseURL        = getBaseURL(),
			verifyChecksum = ( settings.verifyChecksum ?: true ),
			force          = arguments.force,
			log            = logCallback()
		);
	}

	/**
	 * Report the state of the cached binary without downloading anything.
	 *
	 * @return struct { present, installedTag, moduleTag, targetTag, inSync, path }.
	 */
	struct function status(){
		var baseDir = getBinaryDirectory();
		var tag     = getReleaseTag();
		return {
			"present"      : downloader.isPresent( baseDir ),
			"installedTag" : downloader.installedTag( baseDir ),
			"moduleTag"    : "v" & downloader.readModuleVersion( getModuleRoot() ),
			"targetTag"    : tag,
			"inSync"       : downloader.isCurrent( baseDir, tag ),
			"path"         : downloader.binaryPathFor( baseDir )
		};
	}

	/************************* PRIVATE HELPERS *************************/

	private string function getModuleRoot(){
		return reReplace( expandPath( "/cbcloudscraper" ), "[\\/]$", "" );
	}

	private string function getBinaryDirectory(){
		var configured = settings.binaryDirectory ?: "";
		if ( len( configured ) ) {
			return reReplace( configured, "[\\/]$", "" );
		}
		return getModuleRoot() & "/bin";
	}

	private string function getReleaseTag(){
		return downloader.resolveTag( getModuleRoot(), settings.binaryReleaseTag ?: "" );
	}

	private string function getBaseURL(){
		return downloader.deriveBaseURL( getModuleRoot(), settings.binaryBaseURL ?: "" );
	}

	private any function logCallback(){
		return function( message ){
			logger.info( message );
		};
	}

	private string function missingMessage( required string baseDir, required string tag ){
		if ( downloader.isPresent( arguments.baseDir ) ) {
			return "The cached cbcloudscraper binary is for a different version (found '" &
			downloader.installedTag( arguments.baseDir ) & "', need '" & arguments.tag & "').";
		}
		return "The cbcloudscraper binary for " & arguments.tag & " is not installed.";
	}

	private string function manualInstructions( required string baseDir ){
		return "Run 'box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=install' to fetch it, " &
		"or download the release asset by hand into '" & getDirectoryFromPath(
			downloader.binaryPathFor( arguments.baseDir )
		) &
		"', or set the 'binaryPath' module setting to an executable you provide.";
	}

}
