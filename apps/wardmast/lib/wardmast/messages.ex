defmodule Wardmast.Messages do
  @moduledoc """
  Ash domain for the inter-agent message queue.

  Replaces gas-town's `tmux send-keys` prompt-injection with a persistent,
  non-intrusive notification + mailbox layer rooted in Ash + Phoenix.PubSub.
  See `Wardmast.Messages.Message` for the kinds and the data model.

  Code creates / reads messages through `Ash` against
  `Wardmast.Messages.Message`, or via the convenience helpers on that module
  (`notify/1`, `send_mail/1`, `inbox/2`, `recent_notifications/1`).
  """

  use Ash.Domain

  resources do
    resource Wardmast.Messages.Message
    resource Wardmast.Messages.MessageReceipt
  end
end
