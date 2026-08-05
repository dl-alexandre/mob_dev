defmodule MobDev.AndroidDeployRecoveryTest do
  use ExUnit.Case, async: true

  alias MobDev.AndroidDeployRecovery

  @bundle "com.example.casein"
  @serial "serial-a"
  @old_owner "oldownerproof001"
  @new_owner "newownerproof001"

  test "rekeys one proven native-ready boundary without deleting the lease" do
    proof = proof()

    assert {:ok, lease} =
             AndroidDeployRecovery.resume(proof, runner(self()),
               owner: @new_owner,
               minimum_age_seconds: 900
             )

    assert lease.phase == :native_ready
    assert lease.owner == @new_owner
    assert lease.serials == [@serial]
    assert_receive {:command, cas_command}
    assert cas_command =~ "test \"$value\" = \"#{proof.record}\""
    assert cas_command =~ "case \"$value\" in \"1|#{@old_owner}|\"*)"
    refute cas_command =~ "${value#"
    assert cas_command =~ "record_next_#{@new_owner}"
    refute cas_command =~ "rm "
    refute cas_command =~ "rm -rf"

    assert_receive {:command, proof_command}
    assert proof_command =~ ".mob_native_deploy_lock/record"
  end

  test "refuses every incomplete or unsafe proof without invoking adb" do
    unsafe = [
      {:lease_age_seconds, 899},
      {:transport, :tcp},
      {:adb_tcp_disabled?, false},
      {:host_deployer_absent?, false},
      {:exact_topology?, false},
      {:package_identity_matches?, false},
      {:apk_signature_verified?, false},
      {:apk_digest_matches?, false},
      {:runtime_provenance_matches?, false},
      {:payload_valid?, false},
      {:staging_clear?, false}
    ]

    Enum.each(unsafe, fn {key, value} ->
      assert {:error, :recovery_proof_refused} =
               AndroidDeployRecovery.resume(Map.put(proof(), key, value), runner(self()),
                 owner: @new_owner,
                 minimum_age_seconds: 900
               )
    end)

    refute_receive {:command, _command}
  end

  test "refuses wrong device, target digest, phase, malformed record, and ambiguous CAS" do
    for changed <- [
          %{serial: "serial-b"},
          %{target_digest: String.duplicate("0", 64)},
          %{phase: :acquired},
          %{record: "malformed"}
        ] do
      assert {:error, :recovery_proof_refused} =
               AndroidDeployRecovery.resume(Map.merge(proof(), changed), runner(self()),
                 owner: @new_owner
               )
    end

    assert {:error, :recovery_cas_ambiguous,
            %{owner: @new_owner, phase: :native_ready, state: :retained_ambiguous}} =
             AndroidDeployRecovery.resume(proof(), fn _args -> {"changed", 1} end,
               owner: @new_owner
             )
  end

  test "rejects invalid recovery owner before invoking adb" do
    assert {:error, :recovery_proof_refused} =
             AndroidDeployRecovery.resume(proof(), runner(self()), owner: "bad")

    refute_receive {:command, _command}
  end

  test "rejects reusing the interrupted owner and a changed post-CAS record" do
    assert {:error, :recovery_proof_refused} =
             AndroidDeployRecovery.resume(proof(), runner(self()), owner: @old_owner)

    assert {:error, :recovery_cas_ambiguous,
            %{owner: @new_owner, phase: :native_ready, state: :retained_ambiguous}} =
             AndroidDeployRecovery.resume(
               proof(),
               fn
                 ["-s", @serial, "shell", command] ->
                   if String.contains?(command, "record_next_"),
                     do: {"", 0},
                     else: {"changed", 0}
               end,
               owner: @new_owner
             )
  end

  test "portable case guard is accepted by an Android-compatible shell grammar" do
    AndroidDeployRecovery.resume(proof(), runner(self()), owner: @new_owner)
    assert_receive {:command, command}

    assert command =~
             "case \"$value\" in \"1|#{@old_owner}|\"*) ;; *) exit 1 ;; esac;"

    refute command =~ "${value#"
    refute command =~ "${value##"

    guard =
      "value=\"$1\"; case \"$value\" in \"1|#{@old_owner}|\"*) exit 0 ;; *) exit 1 ;; esac"

    assert {"", 0} = System.cmd("/bin/sh", ["-c", guard, "recovery-prefix", proof().record])

    assert {"", 1} =
             System.cmd("/bin/sh", [
               "-c",
               guard,
               "recovery-prefix",
               "1|differentowner01|#{target_digest()}|native_ready"
             ])
  end

  test "ambiguous CAS leaves the observed record unchanged and does not reflect runner output" do
    original_record = proof().record
    state = start_supervised!({Agent, fn -> original_record end})
    secret_runner_output = "private-runner-detail-must-not-reflect"

    result =
      AndroidDeployRecovery.resume(
        proof(),
        fn ["-s", @serial, "shell", command] ->
          assert command =~ "case \"$value\" in"
          {secret_runner_output, 1}
        end,
        owner: @new_owner
      )

    assert {:error, :recovery_cas_ambiguous,
            %{owner: @new_owner, phase: :native_ready, state: :retained_ambiguous}} = result

    assert Agent.get(state, & &1) == original_record
    refute inspect(result) =~ secret_runner_output
  end

  defp proof do
    digest = :crypto.hash(:sha256, @serial) |> Base.encode16(case: :lower)
    record = "1|#{@old_owner}|#{digest}|native_ready"

    %{
      version: 1,
      bundle_id: @bundle,
      serial: @serial,
      target_digest: digest,
      phase: :native_ready,
      record: record,
      lease_age_seconds: 3_600,
      transport: :usb,
      adb_tcp_disabled?: true,
      host_deployer_absent?: true,
      exact_topology?: true,
      package_identity_matches?: true,
      apk_signature_verified?: true,
      apk_digest_matches?: true,
      runtime_provenance_matches?: true,
      payload_valid?: true,
      staging_clear?: true
    }
  end

  defp runner(test_pid) do
    fn ["-s", @serial, "shell", command] ->
      send(test_pid, {:command, command})

      if String.contains?(command, "record_next_"),
        do: {"", 0},
        else: {"1|#{@new_owner}|#{target_digest()}|native_ready", 0}
    end
  end

  defp target_digest,
    do: :crypto.hash(:sha256, @serial) |> Base.encode16(case: :lower)
end
