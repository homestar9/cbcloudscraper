/**
 * CommandBox task to install, update, or check the cbcloudscraper executable.
 *
 * Run it from the app that has the module installed:
 *
 *   box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc                       (status)
 *   box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=install       (fetch it now)
 *   box task run taskFile=modules/cbcloudscraper/tasks/Binary.cfc :action=update        (refresh if stale)
 *
 * This is a convenience for pre-fetching at deploy time. It is not required: the module also
 * downloads the binary automatically on the first request. The download logic is shared with
 * the app runtime through models/BinaryDownloader.cfc, so both behave the same way.
 */
component {

	/**
	 * @action    status | install | update. Defaults to status.
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

		// Make the module's components loadable from this CLI task, then build the downloader.
		fileSystemUtil.createMapping( "cbcloudscraperKit", moduleRoot );
		var downloader = new cbcloudscraperKit.models.BinaryDownloader();

		var baseDir    = len( trim( arguments.directory ) ) ? arguments.directory : ( moduleRoot & "/bin" );
		var releaseTag = downloader.resolveTag( moduleRoot, arguments.tag );
		var url        = downloader.deriveBaseURL( moduleRoot, arguments.baseURL );

		var log = function( message ){
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
					baseURL        = url,
					verifyChecksum = arguments.verify,
					force          = true,
					log            = log
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
							baseURL        = url,
							verifyChecksum = arguments.verify,
							force          = true,
							log            = log
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
	 * Print the installed-vs-wanted binary versions and whether they are in sync.
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
	 * The module root is the folder above this task's own tasks/ folder.
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
