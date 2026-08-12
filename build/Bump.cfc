/**
 * Updates the project version and changelog before a release.
 *
 * Run `box run-script bump:patch`, `bump:minor`, or `bump:major` from the project root.
 * The task updates the version in box.json. It also moves the [Unreleased] notes into a dated
 * section for the new version.
 *
 * This task does not commit, tag, or publish anything. Use `:dryRun=true` to preview the changes.
 * Use `:level=none` when the first release already has the correct version number.
 */
component {

	/** Load the shared settings and helper services. */
	function init(){
		variables.config           = new BuildConfig( getDirectoryFromPath( getCurrentTemplatePath() ) );
		variables.settings         = variables.config.getSettings();
		variables.versionService   = new lib.VersionService();
		variables.changelogService = new lib.ChangelogService();
		return this;
	}

	/**
	 * Calculate both file changes before writing either file.
	 *
	 * @level  How much to change the version. Pass an unknown level to print the valid values.
	 * @preid  The prerelease label to use, such as beta or alpha. Only used by the pre levels.
	 *         Defaults to beta when starting a prerelease.
	 * @dryRun Show what would change without writing anything.
	 * @allowPrereleaseRetarget Allow preminor to move an active prerelease to the next minor
	 *                          version. Defaults to false so the version cannot move by accident.
	 */
	function run(
		string level = "patch",
		string preid = "",
		boolean dryRun = false,
		boolean allowPrereleaseRetarget = false
	){
		var requestedLevel = lCase( trim( arguments.level ) );
		if ( !listFindNoCase( variables.versionService.supportedLevels(), requestedLevel ) ) {
			return fail(
				"Unknown level '#arguments.level#'.",
				[
					"major, minor, patch            raise the version. On a prerelease these settle on",
					"                               the version it was leading up to.",
					"prerelease                     step a prerelease forward, beta.3 to beta.4.",
					"premajor, preminor, prepatch   start a prerelease, :preid=beta by default.",
					"none                           keep the version and just date the changelog."
				],
				"The levels you can use"
			);
		}

		var currentVersion = variables.config.version();
		var currentParts   = variables.versionService.parseVersion( currentVersion );
		if (
			requestedLevel == "preminor"
			&& len( currentParts.prerelease )
			&& !arguments.allowPrereleaseRetarget
		) {
			return fail(
				"#currentVersion# is already a prerelease, so preminor was stopped before it could target the next minor version.",
				[
					"box run-script bump:prerelease              advance the current prerelease",
					":allowPrereleaseRetarget=true               deliberately target the next minor prerelease"
				],
				"Choose the intended prerelease action"
			);
		}
		var newVersion     = currentVersion;
		var releaseDate    = dateFormat( now(), "yyyy-mm-dd" );
		var newChangelog   = "";

		try {
			if ( requestedLevel != "none" ) {
				newVersion = variables.versionService.nextVersion(
					currentVersion,
					requestedLevel,
					trim( arguments.preid )
				);
			}

			// Build the complete changelog first. Do not update box.json when the [Unreleased]
			// section is missing or empty.
			newChangelog = buildChangelog( newVersion, releaseDate );
		} catch ( any exception ) {
			if ( exception.type == "BuildVersion.NotPrerelease" ) {
				return fail(
					exception.message,
					[
						"box run-script bump:beta     the next minor release as a beta",
						"box run-script bump:alpha    the same release with an alpha label",
						":level=prepatch              a prerelease of the next patch",
						":level=premajor              a prerelease of the next major"
					],
					"To start a prerelease"
				);
			}
			return error( exception.message );
		}

		if ( arguments.dryRun ) {
			print
				.line()
				.boldYellowLine( "Dry run: nothing was written." )
				.line( "Version:   #currentVersion# -> #newVersion#" )
				.line( "Changelog: notes would move into #### [#newVersion#] - #releaseDate#" )
				.line()
				.boldLine( "The new changelog would start like this:" )
				.line( left( newChangelog, 600 ) )
				.toConsole();
			return;
		}

		if ( newVersion != currentVersion ) {
			setBoxVersion( newVersion );
			print.greenLine( "box.json: #currentVersion# -> #newVersion#" ).toConsole();
		} else {
			print.greenLine( "box.json stays at #currentVersion# (level=none)." ).toConsole();
		}

		fileWrite( variables.config.repoPath( variables.settings.changelog ), newChangelog );
		print.greenLine( "#variables.settings.changelog#: notes moved into #### [#newVersion#] - #releaseDate#" ).toConsole();

		print
			.line()
			.boldMagentaLine( "Now at #newVersion#. Next steps:" )
			.line( "  1. Review:        git diff -- box.json ""#variables.settings.changelog#""" )
			.line( "  2. Stage:         git add box.json ""#variables.settings.changelog#""" )
			.line( "  3. Check staged:  git diff --staged" )
			.line( "  4. Commit:        git commit -m ""Release #newVersion#""" )
			.line( "  5. Check:         box run-script release:check" )
			.line( "  6. Release:       box run-script release" )
			.toConsole();
	}

	// Private helpers

	/**
	 * Print several lines of help, then stop the task with one error line.
	 *
	 * CommandBox removes line breaks from error() messages. Print the detailed help first so its
	 * line breaks remain readable. Then pass only the summary to error(), which ends the task.
	 *
	 * @summary One line saying what went wrong.
	 * @detail  Lines of guidance to print first.
	 * @heading A short label for the guidance.
	 */
	private function fail( required string summary, array detail = [], string heading = "What to do" ){
		if ( arrayLen( arguments.detail ) ) {
			print.line().boldLine( arguments.heading & ":" ).toConsole();
			for ( var line in arguments.detail ) {
				print.yellowLine( "  " & line ).toConsole();
			}
			print.line().toConsole();
		}
		return error( arguments.summary );
	}

	/**
	 * Replace only the version value in box.json so the rest of the file keeps its formatting.
	 *
	 * @version The new version.
	 */
	private function setBoxVersion( required string version ){
		var boxPath    = variables.config.repoPath( "box.json" );
		var packageText = fileRead( boxPath );

		// Replace the text between the first version property's quotes. Do not use a regex replacement
		// group here. A group such as "\1" followed by a version digit can be read as a larger group
		// number and remove characters from the result.
		var versionMatch = reFind( '("version"\s*:\s*")([^"]*)(")', packageText, 1, true );
		if ( !arrayLen( versionMatch.pos ) || versionMatch.pos[ 1 ] == 0 ) {
			return error( "Could not find a ""version"" entry in box.json." );
		}
		var valueStart  = versionMatch.pos[ 3 ];
		var valueLength = versionMatch.len[ 3 ];
		fileWrite(
			boxPath,
			left( packageText, valueStart - 1 )
				& arguments.version
				& mid( packageText, valueStart + valueLength, len( packageText ) )
		);
	}

	/**
	 * Read the changelog and ask ChangelogService to build the updated text.
	 *
	 * @version The version to date the section with.
	 * @date    Today, as YYYY-MM-DD.
	 */
	private string function buildChangelog( required string version, required string date ){
		var changelogPath = variables.config.repoPath( variables.settings.changelog );
		if ( !fileExists( changelogPath ) ) {
			throw(
				type    = "BuildChangelog.MissingFile",
				message = "No #variables.settings.changelog# found in the project root. "
					& "Create one with an ""#### [Unreleased]"" section, or run: "
					& "box task run taskFile=build/Install.cfc"
			);
		}

		return variables.changelogService.moveUnreleasedNotes(
			content       = fileRead( changelogPath ),
			version       = arguments.version,
			date          = arguments.date,
			changelogName = variables.settings.changelog
		);
	}
}
