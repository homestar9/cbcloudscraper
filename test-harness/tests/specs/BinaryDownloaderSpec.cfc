/**
 * Tests BinaryDownloader methods that do not use outside services.
 *
 * These tests do not use the network. They build expected paths from the current operating
 * system, so the same tests work on Windows development machines and Linux CI runners. Test the
 * real download manually with a published GitHub Release.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
	}

	function afterAll(){
		super.afterAll();
	}

	function run(){
		var moduleRoot    = expandPath( "/cbcloudscraper" );
		var moduleVersion = deserializeJSON( fileRead( expandPath( "/cbcloudscraper/box.json" ), "utf-8" ) ).version;

		// Create a directory and its parents. directoryCreate() with extra arguments
		// does not compile on Adobe ColdFusion, so use java.io.File.mkdirs() here.
		var makeDirs = function( required string path ){
			createObject( "java", "java.io.File" ).init( arguments.path ).mkdirs();
		};

		describe( "BinaryDownloader", function(){
			var downloader = "";
			var platform   = "";

			beforeEach( function(){
				downloader = getInstance( "BinaryDownloader@cbcloudscraper" );
				platform   = downloader.getPlatform();
			} );

			it( "reports a self-consistent platform", function(){
				expect( platform.asset ).toBe( "cbcloudscraper-" & platform.dir & ".zip" );
				expect( platform.exe ).toInclude( "cbcloudscraper" );
			} );

			it( "derives the release base URL from box.json repository.url", function(){
				expect( downloader.deriveBaseURL( moduleRoot ) ).toBe( "https://github.com/homestar9/cbcloudscraper/releases/download" );
			} );

			it( "uses an override base URL and trims a trailing slash", function(){
				expect( downloader.deriveBaseURL( moduleRoot, "https://example.com/dl/" ) ).toBe( "https://example.com/dl" );
			} );

			it( "resolves the release tag from the module version, or an override", function(){
				expect( downloader.resolveTag( moduleRoot ) ).toBe( "v" & moduleVersion );
				expect( downloader.resolveTag( moduleRoot, "v9.9.9" ) ).toBe( "v9.9.9" );
			} );

			it( "reads the module version from box.json", function(){
				expect( downloader.readModuleVersion( moduleRoot ) ).toBe( moduleVersion );
			} );

			it( "reports presence, stamp, and currency for a cached binary", function(){
				var dir     = getTempDirectory() & "cbcs-dl-" & createUUID();
				var platDir = dir & "/" & platform.dir;
				try {
					// A new directory has no executable or version tag.
					expect( downloader.isPresent( dir ) ).toBeFalse();
					expect( downloader.installedTag( dir ) ).toBe( "" );
					expect( downloader.isCurrent( dir, "v1.0.0" ) ).toBeFalse();

					// An executable without a version tag is treated as a local build and can be used.
					makeDirs( platDir );
					fileWrite( platDir & "/" & platform.exe, "not a real binary" );
					expect( downloader.isPresent( dir ) ).toBeTrue();
					expect( downloader.installedTag( dir ) ).toBe( "" );
					expect( downloader.isCurrent( dir, "v1.0.0" ) ).toBeTrue();

					// A tagged executable is current only when its tag matches the requested tag.
					fileWrite( platDir & "/.cbcloudscraper-version", "v1.0.0" );
					expect( downloader.installedTag( dir ) ).toBe( "v1.0.0" );
					expect( downloader.isCurrent( dir, "v1.0.0" ) ).toBeTrue();
					expect( downloader.isCurrent( dir, "v2.0.0" ) ).toBeFalse();
				} finally {
					directoryDelete( dir, true );
				}
			} );

			it( "builds the binary path from the base dir and platform", function(){
				var path = replace(
					downloader.binaryPathFor( "C:/tmp/base" ),
					"\",
					"/",
					"all"
				);
				expect( path ).toBe( "C:/tmp/base/" & platform.dir & "/" & platform.exe );
			} );

			it( "calls the progress callback only when the caller provides a function", function(){
				makePublic( downloader, "logMessage" );
				var messages = [];
				downloader.logMessage( function( message ){
					messages.append( arguments.message );
				}, "hello" );
				expect( messages ).toBe( [ "hello" ] );

				// The blank default and a non-function value are ignored without an error.
				downloader.logMessage( "", "ignored" );
				downloader.logMessage( { "not" : "a function" }, "ignored" );
				expect( messages.len() ).toBe( 1 );
			} );
		} );
	}

}
