/**
 * Confirms the cbcloudscraper module loads and its models are wired correctly.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
	}

	function afterAll(){
		super.afterAll();
	}

	function run(){
		describe( "cbcloudscraper module", function(){
			it( "is registered and activated", function(){
				var modules = getController().getSetting( "modules" );
				expect( modules ).toHaveKey( "cbcloudscraper" );
			} );

			it( "exposes its settings", function(){
				var settings = getInstance( dsl = "coldbox:moduleSettings:cbcloudscraper" );
				expect( settings ).toHaveKey( "binaryPath" );
				expect( settings ).toHaveKey( "defaultEngine" );
				expect( settings.engineOrder ).toBeArray();
			} );

			it( "wires the CloudScraper model with its collaborators", function(){
				var cs = getInstance( "CloudScraper@cbcloudscraper" );
				expect( cs ).toBeComponent();
				// The get/post/send methods make up the public API.
				expect( cs ).toHaveKey( "get" );
				expect( cs ).toHaveKey( "post" );
				expect( cs ).toHaveKey( "send" );
			} );

			it( "wires the ProcessRunner and CookieJar models", function(){
				expect( getInstance( "ProcessRunner@cbcloudscraper" ) ).toBeComponent();
				expect( getInstance( "CookieJar@cbcloudscraper" ) ).toBeComponent();
			} );
		} );
	}

}
