defmodule Mix.Tasks.Mob.ProvisionTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Provision

  # ── diagnose_xcodebuild_failure/1 — the user-visible improvement ────────────
  #
  # Each match preserves Apple's exact text so users can paste it into a search
  # engine and find existing community answers. The hint is additive, not a
  # replacement. Snippets below are excerpts of actual `xcodebuild` output we've
  # seen — keep them realistic so future Apple wording changes show up as
  # broken tests.

  describe "diagnose_xcodebuild_failure/1" do
    test "matches 'The attribute name is invalid' (App ID rejected for too long / bad chars)" do
      output = """
      ** BUILD FAILED **

      The following build commands failed:
              Check provisioning profile in another_political_name_app_bis.app
      (1 failure)

      error: An attribute in the provided entity has invalid value:
       The attribute 'name' is invalid: 'XC com example another_political_name_app_bis'
      """

      assert {label, snippet, hint} = Provision.diagnose_xcodebuild_failure(output)
      assert label =~ "Apple rejected"
      assert label =~ "App ID display name"
      # Snippet preserves Apple's exact words — googleable.
      assert snippet =~ "The attribute 'name' is invalid"
      # Hint is actionable — points at mob.exs and `mix mob.new`.
      assert hint =~ "config :mob_dev"
      assert hint =~ "bundle_id"
    end

    test "matches 'No signing certificate' (cert not in keychain)" do
      output = """
      error: No signing certificate "iOS Development" found:
       No "iOS Development" signing certificates matching team ID
      "Q89CW299G8" with a private key were found.
      """

      assert {label, snippet, hint} = Provision.diagnose_xcodebuild_failure(output)
      assert label =~ "signing certificate"
      assert snippet =~ "No signing certificate"
      assert hint =~ "Xcode → Settings → Accounts"
    end

    test "matches 'requires a development team' (no team selected)" do
      output = """
      error: Signing for "MobProvision" requires a development team.
      Select a development team in the Signing & Capabilities editor.
      """

      assert {_, snippet, _} = Provision.diagnose_xcodebuild_failure(output)
      assert snippet =~ "requires a development team"
    end

    test "matches 'There are too many App IDs' (free-tier 3-per-7-days quota)" do
      output = """
      error: Failed to register bundle identifier:
        There are too many App IDs registered. Please delete some
        currently registered App IDs and try again.
      """

      assert {label, snippet, hint} = Provision.diagnose_xcodebuild_failure(output)
      assert label =~ "Free-tier App ID limit"
      assert snippet =~ "too many App IDs"
      assert hint =~ "wait"
      assert hint =~ "reuse"
    end

    test "matches 'Failed to register bundle identifier' (bundle ID owned by another team)" do
      output = """
      error: Failed to register bundle identifier:
       The app identifier "com.acme.foo" cannot be registered to your
       development team. Change your bundle identifier to a unique string.
      """

      assert {label, snippet, hint} = Provision.diagnose_xcodebuild_failure(output)
      assert label =~ "different team"
      assert snippet =~ "Failed to register bundle identifier"
      assert hint =~ "unique"
    end

    test "returns nil for unrecognised errors so caller falls back to generic message" do
      output = """
      ** BUILD FAILED **
      error: Some entirely new Apple error string nobody has seen before.
      """

      assert Provision.diagnose_xcodebuild_failure(output) == nil
    end

    test "snippet is a single-line excerpt, not the full multi-line output" do
      # Important so the snippet is paste-into-Google sized, not a wall of text.
      output = """
      Build settings from command line:
          ...big preamble...

      error: An attribute in the provided entity has invalid value:
       The attribute 'name' is invalid: 'XC com example foo'

      ...trailing build chatter...
      """

      assert {_, snippet, _} = Provision.diagnose_xcodebuild_failure(output)
      refute snippet =~ "preamble"
      refute snippet =~ "trailing"

      refute String.contains?(snippet, "\n"),
             "snippet should be one line so it's pasteable into a search engine; got: #{inspect(snippet)}"
    end

    test "every recognised error includes an Apple-official documentation URL" do
      # We deliberately link `developer.apple.com/help/account/...` URLs
      # rather than third-party walkthroughs — Apple's account-management
      # docs are the most stable reference and least likely to rot.
      # Pin all five matched cases here so a future hint refactor that
      # accidentally drops the link gets caught.
      cases = [
        {"App ID name",
         "error: An attribute in the provided entity has invalid value:\n The attribute 'name' is invalid: 'XC com example x'\n"},
        {"signing cert", "error: No signing certificate \"iOS Development\" found\n"},
        {"no team", "error: Signing for \"X\" requires a development team.\n"},
        {"App ID quota", "error: There are too many App IDs registered. Please delete some\n"},
        {"bundle id taken",
         "error: Failed to register bundle identifier:\n The app identifier \"x\" cannot be registered\n"}
      ]

      for {name, output} <- cases do
        assert {_, _, hint} = Provision.diagnose_xcodebuild_failure(output),
               "expected pattern for #{name} to match"

        assert hint =~ "developer.apple.com/help/account/",
               "#{name}: hint must include an Apple-official help URL; got: #{hint}"
      end
    end

    test "patterns ordered by specificity — App-ID-name matches before bundle-id-taken" do
      # The 'name is invalid' pattern is more specific than the
      # 'Failed to register bundle identifier' header that often
      # accompanies it. We want the more actionable diagnosis to win.
      output = """
      error: Failed to register bundle identifier
      error: The attribute 'name' is invalid: 'XC com example x'
      """

      assert {label, _, _} = Provision.diagnose_xcodebuild_failure(output)
      assert label =~ "App ID display name"
    end
  end

  # ── asc_auth_args/1 — headless provisioning via App Store Connect API key ────
  describe "asc_auth_args/1" do
    test "no env vars set => [] (falls back to the signed-in Xcode account)" do
      assert Provision.asc_auth_args(%{}) == []
      assert Provision.asc_auth_args(%{"UNRELATED" => "x"}) == []
    end

    test "all three set => the three xcodebuild -authenticationKey* flags, in order" do
      env = %{
        "APP_STORE_CONNECT_KEY_ID" => "ABC123",
        "APP_STORE_CONNECT_ISSUER_ID" => "69a6de00-1234",
        "APP_STORE_CONNECT_API_KEY_PATH" => "/keys/AuthKey_ABC123.p8"
      }

      assert Provision.asc_auth_args(env) == [
               "-authenticationKeyID",
               "ABC123",
               "-authenticationKeyIssuerID",
               "69a6de00-1234",
               "-authenticationKeyPath",
               "/keys/AuthKey_ABC123.p8"
             ]
    end

    test "empty-string values count as absent (KEY_ID= is the same as unset)" do
      assert Provision.asc_auth_args(%{
               "APP_STORE_CONNECT_KEY_ID" => "",
               "APP_STORE_CONNECT_ISSUER_ID" => "",
               "APP_STORE_CONNECT_API_KEY_PATH" => ""
             }) == []
    end

    test "partial config raises, naming what's set and what's missing" do
      err =
        assert_raise Mix.Error, fn ->
          Provision.asc_auth_args(%{"APP_STORE_CONNECT_KEY_ID" => "ABC123"})
        end

      assert err.message =~ "Incomplete App Store Connect API key config"
      assert err.message =~ "APP_STORE_CONNECT_KEY_ID"
      assert err.message =~ "APP_STORE_CONNECT_ISSUER_ID"
      assert err.message =~ "APP_STORE_CONNECT_API_KEY_PATH"
    end
  end

  describe "project_pbxproj/4 configuration entitlement contracts" do
    @team "TEAMFAKE01"
    @bundle "com.example.fake-app"
    @profile "iOS Team Store Provisioning Profile: com.example.fake-app"

    test "Debug uses development entitlements; Release uses distribution entitlements" do
      project =
        Provision.project_pbxproj(
          @bundle,
          @team,
          @profile,
          %{debug: "App.entitlements", release: "App.Release.entitlements"}
        )

      debug_cfg = configuration_block(project, "AA00000B /* Debug */")
      release_cfg = configuration_block(project, "AA00000C /* Release */")

      assert debug_cfg =~ "CODE_SIGN_STYLE = Automatic;"
      assert debug_cfg =~ "CODE_SIGN_ENTITLEMENTS = App.entitlements;"
      refute debug_cfg =~ "CODE_SIGN_ENTITLEMENTS = App.Release.entitlements;"
      refute debug_cfg =~ "Apple Distribution"
      refute debug_cfg =~ "PROVISIONING_PROFILE_SPECIFIER"

      assert release_cfg =~ "CODE_SIGN_STYLE = Manual;"
      assert release_cfg =~ ~s(CODE_SIGN_IDENTITY = "Apple Distribution";)
      assert release_cfg =~ "CODE_SIGN_ENTITLEMENTS = App.Release.entitlements;"
      refute release_cfg =~ "CODE_SIGN_ENTITLEMENTS = App.entitlements;"
      assert release_cfg =~ ~s(PROVISIONING_PROFILE_SPECIFIER = "#{@profile}";)

      assert project =~ "App.entitlements"
      assert project =~ "App.Release.entitlements"
      assert project =~ ~s("com.apple.Push")
    end

    test "omits CODE_SIGN_ENTITLEMENTS when neither configuration has push" do
      project = Provision.project_pbxproj(@bundle, @team, @profile, %{debug: nil, release: nil})

      refute project =~ "CODE_SIGN_ENTITLEMENTS"
      refute project =~ "com.apple.Push"
    end

    test "distribution entitlements use production aps-environment and omit get-task-allow" do
      xml = Provision.distribution_entitlements_plist_for_test(@team, @bundle, push?: true)

      assert xml =~ "<key>aps-environment</key>"
      assert xml =~ "<string>production</string>"
      refute xml =~ "<string>development</string>"
      refute xml =~ "<key>get-task-allow</key>"
      assert xml =~ "<string>#{@team}.#{@bundle}</string>"
      assert xml =~ "<string>#{@team}</string>"
      assert xml =~ "<string>#{@team}.*</string>"
      assert xml =~ "beta-reports-active"
    end

    test "distribution entitlements without push omit aps-environment" do
      xml = Provision.distribution_entitlements_plist_for_test(@team, @bundle, push?: false)

      refute xml =~ "<key>aps-environment</key>"
      refute xml =~ "<key>get-task-allow</key>"
    end

    defp configuration_block(project, marker) do
      case Regex.run(~r/#{Regex.escape(marker)} = \{(.*?)\t\t\};/s, project) do
        [_, block] -> block
        _ -> flunk("missing configuration #{marker}")
      end
    end
  end
end
