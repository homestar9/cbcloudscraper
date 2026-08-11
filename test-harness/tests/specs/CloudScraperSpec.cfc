/**
 * Tests for the CloudScraper model.
 *
 * Most tests inject a MockRunner so they run on any engine and operating system without
 * the real executable. They check that CloudScraper builds the request correctly, decodes
 * the response, maps headers and cookies, and handles operational failures. One test at
 * the end uses the real binary and is skipped automatically when the binary is not built.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
	}

	function afterAll(){
		super.afterAll();
	}

	function run(){
		// Is the real Windows binary present locally? Used to decide whether to run the live
		// test. The binary is no longer a fixed setting, so check its default location.
		var hasBinary = fileExists( expandPath( "/cbcloudscraper/bin/win64/cbcloudscraper.exe" ) );

		describe( "CloudScraper", function(){
			var cs         = "";
			var mockRunner = "";
			var realRunner = "";

			beforeEach( function(){
				cs         = getInstance( "CloudScraper@cbcloudscraper" );
				realRunner = cs.getRunner(); // keep the real runner to restore later
				mockRunner = new tests.resources.MockRunner();
				cs.setRunner( mockRunner ); // swap in the mock for this test
			} );

			afterEach( function(){
				// CloudScraper is a singleton; put the real runner back so other tests and
				// the live test are not affected.
				cs.setRunner( realRunner );
			} );

			it( "returns a decoded body, status, headers and cookies on success", function(){
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeTrue();
				expect( result.statusCode ).toBe( 200 );
				expect( result.engineUsed ).toBe( "curl_cffi" );
				expect( result.fileContent ).toBe( "Hello, cbcloudscraper!" );
				expect( result.charset ).toBe( "utf-8" );

				// Convenience header struct plus the full raw header list.
				expect( result.headers ).toHaveKey( "Content-Type" );
				expect( result.rawHeaders.len() ).toBe( 2 );

				expect( result.cookies.len() ).toBe( 1 );
				expect( result.cookies[ 1 ].name ).toBe( "cf_clearance" );
			} );

			it( "sends the method, engine, and a URL-encoded form body for post()", function(){
				cs.post(
					url     = "https://example.com/submit",
					body    = { "a" : "1", "b" : "2" },
					options = { "engine" : "curl_cffi" }
				);

				var sent = mockRunner.getLastRequest();
				expect( sent.method ).toBe( "POST" );
				expect( sent.engine ).toBe( "curl_cffi" );

				var decodedBody = charsetEncode( binaryDecode( sent.bodyBase64, "base64" ), "utf-8" );
				expect( decodedBody ).toInclude( "a=1" );
				expect( decodedBody ).toInclude( "b=2" );
			} );

			it( "applies per-request options and extra headers", function(){
				cs.get(
					url     = "https://example.com",
					options = {
						"timeout"     : 15,
						"impersonate" : "chrome131",
						"headers"     : { "X-Test" : "yes" }
					}
				);

				var sent = mockRunner.getLastRequest();
				expect( sent.timeoutSeconds ).toBe( 15 );
				expect( sent.impersonate ).toBe( "chrome131" );
				expect( sent.headers[ "X-Test" ] ).toBe( "yes" );
			} );

			it( "returns ok=false with a timeout message when the process times out", function(){
				mockRunner.setBehavior( "timeout" );
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeFalse();
				expect( result.statusCode ).toBe( 0 );
				expect( result.errorDetail ).toInclude( "timeout" );
			} );

			it( "returns ok=false when no response file is produced", function(){
				mockRunner.setBehavior( "noFile" );
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeFalse();
				expect( result.errorDetail ).toInclude( "no response" );
			} );

			it( "returns ok=false when the worker reports an error", function(){
				mockRunner.setBehavior( "errorResponse" );
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeFalse();
				expect( result.errorDetail ).toInclude( "boom" );
			} );

			it( "returns ok=false when the response is malformed", function(){
				mockRunner.setBehavior( "malformed" );
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeFalse();
				expect( len( result.errorDetail ) ).toBeGT( 0 );
			} );

			it( "throws when throwOnError is set and an operational error occurs", function(){
				mockRunner.setBehavior( "timeout" );
				expect( function(){
					cs.get( url = "https://example.com", options = { "throwOnError" : true } );
				} ).toThrow( type = "cbcloudscraper.RequestException" );
			} );

			it( "returns ok=false when an explicitly set binary path does not exist", function(){
				var settings        = getInstance( dsl = "coldbox:moduleSettings:cbcloudscraper" );
				var original        = settings.binaryPath;
				settings.binaryPath = "Z:/does/not/exist/cbcloudscraper.exe";
				try {
					var result = cs.get( "https://example.com" );
					expect( result.ok ).toBeFalse();
					expect( result.errorDetail ).toInclude( "does not exist" );
				} finally {
					settings.binaryPath = original;
				}
			} );

			it(
				title = "fetches a live URL through the real binary (Windows, built binary only)",
				skip  = !hasBinary,
				body  = function(){
					// Use the real runner instead of the mock for this one test.
					cs.setRunner( getInstance( "ProcessRunner@cbcloudscraper" ) );

					var result = cs.get( "https://example.com" );

					expect( result.ok ).toBeTrue();
					expect( result.statusCode ).toBe( 200 );
					expect( result.fileContent ).toInclude( "Example Domain" );
					expect( result.engineUsed ).toBe( "curl_cffi" );
				}
			);
		} );
	}

}
