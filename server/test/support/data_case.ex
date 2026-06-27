defmodule Pux.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Pux.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Pux.DataCase
    end
  end

  setup tags do
    Pux.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Pux.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
