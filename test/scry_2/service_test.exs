defmodule Scry2.ServiceTest do
  use ExUnit.Case, async: true

  alias Scry2.Service
  alias Scry2.Service.Backend

  describe "detect/1" do
    test "returns Systemd when INVOCATION_ID is set" do
      env_fn = fn
        "INVOCATION_ID" -> "abc123"
        _ -> nil
      end

      assert Service.detect(env_fn: env_fn, mix_env: :dev) == Backend.Systemd
    end

    test "returns Tray when SCRY2_SUPERVISOR=tray" do
      env_fn = fn
        "INVOCATION_ID" -> nil
        "SCRY2_SUPERVISOR" -> "tray"
        _ -> nil
      end

      assert Service.detect(env_fn: env_fn, mix_env: :dev) == Backend.Tray
    end

    test "returns Tray in :prod when neither env var is set" do
      env_fn = fn _ -> nil end
      assert Service.detect(env_fn: env_fn, mix_env: :prod) == Backend.Tray
    end

    test "returns Unmanaged in :dev when no supervisor signals" do
      env_fn = fn _ -> nil end
      assert Service.detect(env_fn: env_fn, mix_env: :dev) == Backend.Unmanaged
    end

    test "returns Unmanaged in :test when no supervisor signals" do
      env_fn = fn _ -> nil end
      assert Service.detect(env_fn: env_fn, mix_env: :test) == Backend.Unmanaged
    end

    test "Systemd takes precedence over SCRY2_SUPERVISOR" do
      env_fn = fn
        "INVOCATION_ID" -> "x"
        "SCRY2_SUPERVISOR" -> "tray"
        _ -> nil
      end

      assert Service.detect(env_fn: env_fn, mix_env: :prod) == Backend.Systemd
    end

    test "empty INVOCATION_ID does not count as systemd" do
      env_fn = fn
        "INVOCATION_ID" -> ""
        _ -> nil
      end

      assert Service.detect(env_fn: env_fn, mix_env: :dev) == Backend.Unmanaged
    end
  end

  describe "facade delegates to detected backend" do
    test "name/1 forwards to backend" do
      assert Service.name(backend: Backend.Unmanaged) == "unmanaged"
      assert Service.name(backend: Backend.Tray) == "tray"
    end

    test "capabilities/1 forwards to backend" do
      assert Service.capabilities(backend: Backend.Unmanaged) ==
               %{can_restart: false, can_stop: false, can_status: true}

      assert Service.capabilities(backend: Backend.Tray) ==
               %{can_restart: true, can_stop: false, can_status: true}

      assert Service.capabilities(backend: Backend.Systemd) ==
               %{can_restart: true, can_stop: true, can_status: true}
    end

    test "restart/1 forwards to backend" do
      assert Service.restart(backend: Backend.Unmanaged) == :not_supported
    end

    test "stop/1 forwards to backend" do
      assert Service.stop(backend: Backend.Tray) == :not_supported
      assert Service.stop(backend: Backend.Unmanaged) == :not_supported
    end
  end
end
