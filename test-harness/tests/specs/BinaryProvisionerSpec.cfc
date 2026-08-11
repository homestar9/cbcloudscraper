/**
 * Tests for BinaryProvisioner.
 *
 * These are hermetic: they never reach the network. They cover the resolution paths that
 * do not require a download — an explicitly configured binary, a missing explicit binary,
 * and the "auto-download turned off" error. The real download path is verified by hand
 * against a published GitHub Release (see the plan's verification steps).
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
	}

	function afterAll(){
		super.afterAll();
	}

	function run(){
		// The binary the local build produces, if present. Used for the short-circuit test.
		var localBinary    = expandPath( "/cbcloudscraper/bin/win64/cbcloudscraper.exe" );
		var hasLocalBinary = fileExists( localBinary );

		describe( "BinaryProvisioner", function(){
			var provisioner = "";
			var settings    = "";
			var saved       = {};

			beforeEach( function(){
				provisioner = getInstance( "BinaryProvisioner@cbcloudscraper" );
				settings    = getInstance( dsl = "coldbox:moduleSettings:cbcloudscraper" );
				// Save the settings this suite changes, so each test starts clean.
				saved       = {
					"binaryPath"         : settings.binaryPath,
					"binaryDirectory"    : settings.binaryDirectory,
					"autoDownloadBinary" : settings.autoDownloadBinary
				};
			} );

			afterEach( function(){
				settings.binaryPath         = saved.binaryPath;
				settings.binaryDirectory    = saved.binaryDirectory;
				settings.autoDownloadBinary = saved.autoDownloadBinary;
			} );

			it( "returns an explicitly configured binary that exists", function(){
				var fake = getTempDirectory() & "cbcs-fake-" & createUUID() & ".exe";
				fileWrite( fake, "not a real binary" );
				try {
					settings.binaryPath = fake;
					expect( provisioner.ensureBinary() ).toBe( fake );
				} finally {
					fileDelete( fake );
				}
			} );

			it( "throws when the explicit binary path does not exist", function(){
				settings.binaryPath = "Z:/nope/cbcloudscraper.exe";
				expect( function(){
					provisioner.ensureBinary();
				} ).toThrow( type = "cbcloudscraper.BinaryUnavailable" );
			} );

			it( "throws with manual instructions when auto-download is off and no binary is present", function(){
				// Point at an empty directory so no cached binary is found, and disable download.
				var emptyDir = getTempDirectory() & "cbcs-empty-" & createUUID();
				directoryCreate( emptyDir, true, true );
				try {
					settings.binaryPath         = "";
					settings.binaryDirectory    = emptyDir;
					settings.autoDownloadBinary = false;
					expect( function(){
						provisioner.ensureBinary();
					} ).toThrow( type = "cbcloudscraper.BinaryUnavailable" );
				} finally {
					directoryDelete( emptyDir, true );
				}
			} );

			it(
				title = "returns the locally built binary without downloading (when it exists)",
				skip  = !hasLocalBinary,
				body  = function(){
					settings.binaryPath      = "";
					settings.binaryDirectory = ""; // default: the module's own bin/ folder
					// Compare with slashes normalized: both point to the same file, but the
					// provisioner joins path parts with "/" while expandPath uses "\".
					var resolved             = replace( provisioner.ensureBinary(), "\", "/", "all" );
					expect( resolved ).toBe( replace( localBinary, "\", "/", "all" ) );
				}
			);
		} );
	}

}
