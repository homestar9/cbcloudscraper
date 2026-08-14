/**
 * Finds a usable cbcloudscraper executable and downloads one when needed.
 *
 * Git does not store the executable. Each GitHub Release provides a separate download for each
 * supported operating system. On the first request, this component checks the cached executable.
 * BinaryProvisioner downloads, verifies, and unpacks the correct file when the cache is missing
 * or out of date.
 * Later requests return the cached path without downloading the file again.
 *
 * BinaryDownloader contains the download code. The application and tasks/Binary.cfc both use
 * BinaryDownloader, so both entry points follow the same rules.
 *
 * An application can set binaryPath to use an executable that is already on the server. This
 * option is useful when the server cannot download files from the internet.
 */
component singleton accessors="true" {

	property name="settings"   inject="coldbox:moduleSettings:cbcloudscraper";
	property name="downloader" inject="BinaryDownloader@cbcloudscraper";
	property name="logger"     inject="logbox:logger:{this}";

	/**
	 * Return the full path to a usable executable. Download the executable when needed.
	 *
	 * Throw cbcloudscraper.BinaryUnavailable when the executable cannot be used or downloaded.
	 */
	string function ensureBinary(){
		// Use binaryPath first because the application provided that executable directly.
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

		// Reuse a current download or an untagged local development build.
		if ( downloader.isCurrent( baseDir, tag ) ) {
			return downloader.binaryPathFor( baseDir );
		}

		// The cached executable is missing or outdated. Download it or report why that is disabled.
		// structKeyExists is used instead of ?: because Adobe ColdFusion's ?: treats a boolean
		// false value like a missing value and would replace it with true.
		if ( !( structKeyExists( settings, "autoDownloadBinary" ) ? settings.autoDownloadBinary : true ) ) {
			throw(
				type    = "cbcloudscraper.BinaryUnavailable",
				message = missingMessage( baseDir, tag ),
				detail  = "Automatic download is turned off (autoDownloadBinary=false). " & manualInstructions(
					baseDir
				)
			);
		}

		// Allow one download at a time. Waiting requests reuse the file after the download finishes.
		lock name="cbcloudscraper-binary-#hash( baseDir, "MD5" )#" type="exclusive" timeout="300" {
			if ( downloader.isCurrent( baseDir, tag ) ) {
				return downloader.binaryPathFor( baseDir );
			}
			downloader.ensure(
				baseDir        = baseDir,
				tag            = tag,
				baseURL        = getBaseURL(),
				verifyChecksum = ( structKeyExists( settings, "verifyChecksum" ) ? settings.verifyChecksum : true ),
				force          = false,
				onProgress     = logCallback(),
				strictChecksum = ( structKeyExists( settings, "strictChecksum" ) ? settings.strictChecksum : false ),
				onWarning      = warnCallback()
			);
		}

		return downloader.binaryPathFor( baseDir );
	}

	/**
	 * Download the executable for the current module version and replace the cached copy.
	 * Application startup code can call this method to download the file before the first request.
	 *
	 * @force Download even when the cache already matches the requested version.
	 *
	 * @return The BinaryDownloader result with action, path, tag, and present values.
	 */
	struct function install( boolean force = true ){
		return downloader.ensure(
			baseDir        = getBinaryDirectory(),
			tag            = getReleaseTag(),
			baseURL        = getBaseURL(),
			verifyChecksum = ( structKeyExists( settings, "verifyChecksum" ) ? settings.verifyChecksum : true ),
			force          = arguments.force,
			onProgress     = logCallback(),
			strictChecksum = ( structKeyExists( settings, "strictChecksum" ) ? settings.strictChecksum : false ),
			onWarning      = warnCallback()
		);
	}

	/**
	 * Return the cached executable's status without downloading anything.
	 *
	 * @return A struct with present, installedTag, moduleTag, targetTag, inSync, and path values.
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

	// Private helpers

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

	/**
	 * A callback for messages that should stand out in a production log, such as a download whose
	 * checksum could not be checked. Progress messages go to info, which is easy to miss.
	 */
	private any function warnCallback(){
		return function( message ){
			logger.warn( message );
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
