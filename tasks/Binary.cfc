/**
 * Installs, updates, or checks the cbcloudscraper executable from CommandBox.
 *
 * Run one of these commands from an application that has the module installed:
 *
 *   box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc
 *   box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=install
 *   box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=update
 *
 * Use this task to download the executable during deployment. Running it is optional because
 * the module can download the executable on the first request. This task and the application
 * both use models/BinaryDownloader.cfc, so they follow the same download rules.
 */
component {

	/**
	 * @action    The action to run: status, install, or update. Defaults to status.
	 * @directory Where to install the binary. Defaults to the module's own bin/ folder.
	 * @tag       Force a release tag, for example v1.0.0. Defaults to "v" + the module version.
	 * @baseURL   Force the release download base URL. Defaults to the module's repository releases.
	 * @verify    Verify the download's SHA-256. Defaults to true.
	 */
	function run(
		string action    = "status",
		string directory = "",
		string tag       = "",
		string baseURL   = "",
		boolean verify   = true
	){
		var moduleRoot = resolveModuleRoot();

		// Add a CFML mapping so this task can create the shared BinaryDownloader component.
		fileSystemUtil.createMapping( "cbcloudscraperKit", moduleRoot );
		var downloader = new cbcloudscraperKit.models.BinaryDownloader();

		var baseDir        = len( trim( arguments.directory ) ) ? arguments.directory : ( moduleRoot & "/bin" );
		var releaseTag     = downloader.resolveTag( moduleRoot, arguments.tag );
		// Not named "url" because Lucee resolves that identifier to the URL scope, not the local variable.
		var releaseBaseURL = downloader.deriveBaseURL( moduleRoot, arguments.baseURL );

		var onProgress = function( message ){
			print.line( message ).toConsole();
		};

		switch ( lCase( trim( arguments.action ) ) ) {
			case "status":
				printStatus( downloader, moduleRoot, baseDir, releaseTag );
				break;
			case "install":
				print.line( "Installing cbcloudscraper binary " & releaseTag & "..." ).toConsole();
				var installed = downloader.ensure(
					baseDir        = baseDir,
					tag            = releaseTag,
					baseURL        = releaseBaseURL,
					verifyChecksum = arguments.verify,
					force          = true,
					onProgress     = onProgress
				);
				print.greenLine( "Done (" & installed.action & "): " & installed.path ).toConsole();
				break;
			case "update":
				if ( downloader.isCurrent( baseDir, releaseTag ) ) {
					print.greenLine( "Already up to date: binary " & releaseTag & " is installed." ).toConsole();
				} else {
					var present = downloader.isPresent( baseDir );
					var prompt  = present
					 ? "A different binary is installed (" & (
						len( downloader.installedTag( baseDir ) ) ? downloader.installedTag( baseDir ) : "unversioned"
					) & "). Download " & releaseTag & "? [y/n]"
					 : "The binary is not installed. Download " & releaseTag & "? [y/n]";
					if ( confirm( prompt ) ) {
						var updated = downloader.ensure(
							baseDir        = baseDir,
							tag            = releaseTag,
							baseURL        = releaseBaseURL,
							verifyChecksum = arguments.verify,
							force          = true,
							onProgress     = onProgress
						);
						print.greenLine( "Done (" & updated.action & "): " & updated.path ).toConsole();
					} else {
						print.yellowLine( "Skipped." ).toConsole();
					}
				}
				print
					.line( "To update the module itself (and its target binary version), run: box update cbcloudscraper" )
					.toConsole();
				break;
			default:
				return error( "Unknown action '" & arguments.action & "'. Use status, install, or update." );
		}
	}

	/**
	 * Print the installed version, required version, and whether the versions match.
	 */
	private function printStatus(
		required any downloader,
		required string moduleRoot,
		required string baseDir,
		required string releaseTag
	){
		var present   = arguments.downloader.isPresent( arguments.baseDir );
		var installed = arguments.downloader.installedTag( arguments.baseDir );
		var inSync    = arguments.downloader.isCurrent( arguments.baseDir, arguments.releaseTag );

		print.line();
		print.boldLine( "cbcloudscraper binary status" );
		print.line( "  module version : " & arguments.downloader.readModuleVersion( arguments.moduleRoot ) );
		print.line( "  wanted release : " & arguments.releaseTag );
		print.line( "  installed      : " & (
			present ? ( len( installed ) ? installed : "(present, no version stamp)" ) : "(not installed)"
		) );
		print.line( "  location       : " & arguments.downloader.binaryPathFor( arguments.baseDir ) );
		if ( inSync ) {
			print.greenLine( "  in sync        : yes" );
		} else {
			print.yellowLine( "  in sync        : no  (run this task with :action=install or :action=update)" );
		}
		print.line().toConsole();
	}

	/**
	 * Return the module directory that contains this task's tasks directory.
	 */
	private string function resolveModuleRoot(){
		var taskDir = reReplace(
			getDirectoryFromPath( getCurrentTemplatePath() ),
			"[\\/]$",
			""
		);
		return reReplace( taskDir, "[\\/][^\\/]+$", "" );
	}

}
