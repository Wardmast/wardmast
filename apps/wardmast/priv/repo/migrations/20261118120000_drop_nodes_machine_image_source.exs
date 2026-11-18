defmodule Arbiter.Repo.Migrations.DropNodesMachineImageSource do
  @moduledoc """
  SI13 (`docs/design/remote-workers.md` §21.6 step 6): `nodes.machine_image_source` is
  retired with build-from-plan on nodes; every machine node pulls the published image.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      remove :nodes_machine_image_source, :string
    end
  end
end
