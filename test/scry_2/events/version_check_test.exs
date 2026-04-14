defmodule Scry2.Events.VersionCheckTest do
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.Events.PipelineHash
  alias Scry2.Events.ProjectorRegistry
  alias Scry2.Events.VersionCheck

  @translator_key "__translator__"

  describe "determine_action/0" do
    test "returns :store_initial on first run with no stored hashes" do
      assert :store_initial = VersionCheck.determine_action()
    end

    test "returns :up_to_date when all hashes match" do
      store_current_hashes!()

      assert :up_to_date = VersionCheck.determine_action()
    end

    test "returns :reingest when translator hash differs" do
      Events.put_content_hash!(@translator_key, "stale_hash")
      store_projector_hashes!()

      assert :reingest = VersionCheck.determine_action()
    end

    test "returns {:rebuild_projectors, [mod]} when a projector hash differs" do
      Events.put_content_hash!(@translator_key, PipelineHash.translator_hash())

      [stale_projector | rest] = ProjectorRegistry.all()
      Events.put_content_hash!(stale_projector.projector_name(), "stale_projector_hash")

      for mod <- rest do
        Events.put_content_hash!(mod.projector_name(), mod.content_hash())
      end

      assert {:rebuild_projectors, [^stale_projector]} = VersionCheck.determine_action()
    end

    test "returns multiple stale projectors when several changed" do
      Events.put_content_hash!(@translator_key, PipelineHash.translator_hash())

      for mod <- ProjectorRegistry.all() do
        Events.put_content_hash!(mod.projector_name(), "stale")
      end

      {:rebuild_projectors, stale} = VersionCheck.determine_action()
      assert length(stale) == length(ProjectorRegistry.all())
    end

    test "stores hash for new projector (nil stored) and excludes it from stale" do
      Events.put_content_hash!(@translator_key, PipelineHash.translator_hash())

      # Store hashes for all but the first projector — simulates adding a new one
      [new_projector | rest] = ProjectorRegistry.all()

      for mod <- rest do
        Events.put_content_hash!(mod.projector_name(), mod.content_hash())
      end

      assert :up_to_date = VersionCheck.determine_action()

      # The new projector's hash was stored during the check
      assert Events.get_content_hash(new_projector.projector_name()) ==
               new_projector.content_hash()
    end
  end

  describe "execute!/1" do
    test ":store_initial stores all hashes" do
      VersionCheck.execute!(:store_initial)

      assert Events.get_content_hash(@translator_key) == PipelineHash.translator_hash()

      for mod <- ProjectorRegistry.all() do
        assert Events.get_content_hash(mod.projector_name()) == mod.content_hash()
      end
    end

    test ":up_to_date is a no-op" do
      assert :ok = VersionCheck.execute!(:up_to_date)
    end
  end

  describe "start_link/1" do
    test "returns :ignore so supervisor moves on" do
      assert :ignore = VersionCheck.start_link([])
    end

    test "stores hashes on first run" do
      VersionCheck.start_link([])

      assert Events.get_content_hash(@translator_key) == PipelineHash.translator_hash()

      for mod <- ProjectorRegistry.all() do
        assert Events.get_content_hash(mod.projector_name()) == mod.content_hash()
      end
    end

    test "is idempotent — second run with same hashes is up_to_date" do
      VersionCheck.start_link([])
      store_current_hashes!()

      assert :up_to_date = VersionCheck.determine_action()
    end
  end

  defp store_current_hashes! do
    Events.put_content_hash!(@translator_key, PipelineHash.translator_hash())
    store_projector_hashes!()
  end

  defp store_projector_hashes! do
    for mod <- ProjectorRegistry.all() do
      Events.put_content_hash!(mod.projector_name(), mod.content_hash())
    end
  end
end
