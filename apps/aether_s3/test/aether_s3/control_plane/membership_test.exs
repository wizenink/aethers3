defmodule AetherS3.ControlPlane.MembershipTest do
  # NOT async: overrides the global :data_dir to an isolated temp path.
  use ExUnit.Case

  alias AetherS3.ControlPlane.Membership

  setup do
    prev = Application.get_env(:aether_s3, :data_dir)
    dir = Path.join(System.tmp_dir!(), "cpnode-#{System.unique_integer([:positive])}")
    Application.put_env(:aether_s3, :data_dir, dir)

    on_exit(fn ->
      Application.put_env(:aether_s3, :data_dir, prev)
      File.rm_rf(dir)
    end)

    :ok
  end

  test "a fresh data dir has no recorded node and reports no change" do
    assert Membership.recorded_node() == nil
    refute Membership.node_changed?()
  end

  test "record_node stamps the current node; the same node is not a change" do
    Membership.record_node()
    assert Membership.recorded_node() == to_string(Node.self())
    refute Membership.node_changed?()
  end

  test "a marker from a different node name is detected as a change" do
    File.mkdir_p!(Membership.data_dir())
    File.write!(Membership.node_marker_path(), "aether1@otherhost")
    assert Membership.node_changed?()
  end

  test "wipe_khepri clears the node marker" do
    Membership.record_node()
    assert Membership.recorded_node() != nil

    Membership.wipe_khepri()
    assert Membership.recorded_node() == nil
  end
end
