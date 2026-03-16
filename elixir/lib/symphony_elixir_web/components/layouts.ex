defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  alias SymphonyElixirWeb.StaticAssets

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src={versioned_asset_path("/vendor/phoenix_html/phoenix_html.js")}></script>
        <script defer src={versioned_asset_path("/vendor/phoenix/phoenix.js")}></script>
        <script defer src={versioned_asset_path("/vendor/phoenix_live_view/phoenix_live_view.js")}></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");
            var body = document.body;

            function setDashboardSocketState(isConnected) {
              if (!body) return;

              body.classList.toggle("dashboard-live-connected", !!isConnected);
              body.classList.toggle("dashboard-live-disconnected", !isConnected);
            }

            window.copyDashboardText = async function (button) {
              if (!button) return false;

              var text = button.dataset.copy || "";
              var label = button.dataset.label || "Copy";

              function resetButton(nextLabel) {
                button.textContent = nextLabel;
                clearTimeout(button._copyTimer);
                button._copyTimer = setTimeout(function () {
                  button.textContent = label;
                }, 1200);
              }

              async function copyWithClipboardApi() {
                if (!window.isSecureContext || !navigator.clipboard?.writeText) return false;

                try {
                  await navigator.clipboard.writeText(text);
                  return true;
                } catch (_error) {
                  return false;
                }
              }

              function copyWithExecCommand() {
                var textarea = document.createElement("textarea");
                textarea.value = text;
                textarea.setAttribute("readonly", "");
                textarea.setAttribute("aria-hidden", "true");
                textarea.style.position = "fixed";
                textarea.style.top = "0";
                textarea.style.left = "0";
                textarea.style.width = "1px";
                textarea.style.height = "1px";
                textarea.style.padding = "0";
                textarea.style.opacity = "0";
                textarea.style.pointerEvents = "none";
                textarea.style.fontSize = "16px";

                document.body.appendChild(textarea);
                textarea.focus();
                textarea.select();
                textarea.setSelectionRange(0, textarea.value.length);

                try {
                  return !!document.execCommand && document.execCommand("copy");
                } catch (_error) {
                  return false;
                } finally {
                  textarea.remove();
                }
              }

              var copied = await copyWithClipboardApi();

              if (!copied) {
                copied = copyWithExecCommand();
              }

              if (copied) {
                resetButton("Copied");
                return false;
              }

              window.prompt("Copy this session ID", text);
              resetButton("Select text");
              return false;
            };

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            setDashboardSocketState(false);

            if (liveSocket.socket?.onOpen) {
              liveSocket.socket.onOpen(function () {
                setDashboardSocketState(true);
              });
            }

            if (liveSocket.socket?.onClose) {
              liveSocket.socket.onClose(function () {
                setDashboardSocketState(false);
              });
            }

            liveSocket.connect();
            setDashboardSocketState(liveSocket.socket?.isConnected?.() === true);
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href={versioned_asset_path("/dashboard.css")} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end

  defp versioned_asset_path(path) when is_binary(path) do
    case StaticAssets.version(path) do
      {:ok, version} -> "#{path}?v=#{version}"
      :error -> path
    end
  end
end
