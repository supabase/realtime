defmodule RealtimeWeb.Components do
  @moduledoc """
  Components for LiveView
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS
  alias Phoenix.HTML.Form

  @doc """
  Renders an h1 tag.
  ## Examples
      <.h1>My Header</.h1>
  """
  slot(:inner_block, required: true)

  def h1(assigns) do
    ~H"""
    <h1 class="mb-5 flex items-center text-2xl font-semibold leading-6 text-brand"><%= render_slot(@inner_block) %></h1>
    """
  end

  @doc """
  Renders an h2 tag.
  ## Examples
      <.h2>My Header</.h2>
  """
  slot(:inner_block, required: true)

  def h2(assigns) do
    ~H"""
    <h2 class="mb-5 flex items-center text-lg font-semibold leading-6 text-brand"><%= render_slot(@inner_block) %></h2>
    """
  end

  @doc """
  Renders an h3 tag.
  ## Examples
      <.h3>My Header</.h3>
  """
  slot(:inner_block, required: true)

  def h3(assigns) do
    ~H"""
    <h3 class="mb-5 flex items-center text-lg font-semibold leading-6 text-brand"><%= render_slot(@inner_block) %></h3>
    """
  end

  @doc """
  Renders a button.
  ## Examples
      <.button>Send!</.button>
      <.button phx-click="go" class="ml-2">Send!</.button>
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global

  slot(:inner_block, required: true)

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={["bg-green-600 hover:bg-green-500 text-white font-bold py-2 px-4 rounded focus:outline-none", @class]}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  @doc """
  Renders a link as a button.
  ## Examples
      <.link_button>Send!</.link_button>
  """
  attr :href, :string, default: "#"
  attr :target, :string, default: ""
  attr :rest, :global

  slot(:inner_block, required: true)

  def link_button(assigns) do
    ~H"""
    <.link
      role="button"
      class="bg-green-600 hover:bg-green-500 text-white font-bold py-2 px-4 rounded focus:outline-none"
      href={@href}
      target={@target}
      {@rest}>
      <%= render_slot(@inner_block) %>
    </.link>
    """
  end

  @doc """
  Renders a link as a button.
  ## Examples
      <.link_button>Send!</.link_button>
  """
  attr :href, :string, default: "#"
  attr :target, :string, default: ""
  attr :rest, :global

  slot(:inner_block, required: true)

  def gray_link_button(assigns) do
    ~H"""
    <.link
      role="button"
      class="bg-gray-600 hover:bg-gray-500 text-white font-bold py-2 px-4 rounded focus:outline-none"
      href={@href}
      target={@target}
      {@rest}>
      <%= render_slot(@inner_block) %>
    </.link>
    """
  end

  @doc """
  Renders a link as a button, but optionally patches the browser history.
  ## Examples
      <.patch_button>Send!</.link_button>
  """
  attr :patch, :string, default: "#"
  attr :replace, :boolean, default: true
  attr :target, :string, default: ""
  attr :rest, :global

  slot(:inner_block, required: true)

  def patch_button(assigns) do
    ~H"""
    <.link
      role="button"
      class="bg-green-600 hover:bg-green-500 text-white font-bold py-2 px-4 rounded focus:outline-none"
      patch={@patch}
      replace={@replace}
      target={@target}
      {@rest}>
      <%= render_slot(@inner_block) %>
    </.link>
    """
  end

  @doc """
  Renders a modal.
  ## Examples
      <.modal id="confirm-modal">
        Are you sure?
        <:confirm>OK</:confirm>
        <:cancel>Cancel</:cancel>
      </.modal>
  JS commands may be passed to the `:on_cancel` and `on_confirm` attributes
  for the caller to reactor to each button press, for example:
      <.modal id="confirm" on_confirm={JS.push("delete")} on_cancel={JS.navigate(~p"/posts")}>
        Are you sure you?
        <:confirm>OK</:confirm>
        <:cancel>Cancel</:cancel>
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  attr :on_confirm, JS, default: %JS{}

  slot(:inner_block, required: true)
  slot(:title)
  slot(:subtitle)
  slot(:confirm)
  slot(:cancel)

  def modal(assigns) do
    ~H"""
    <div id={@id} phx-mounted={@show && show_modal(@id)} class="relative z-50 hidden">
      <div id={"#{@id}-bg"} class="fixed inset-0 bg-zinc-50/90 transition-opacity" aria-hidden="true" />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center">
          <div class="w-full max-w-3xl p-4 sm:p-6 lg:py-8">
            <.focus_wrap
              id={"#{@id}-container"}
              phx-mounted={@show && show_modal(@id)}
              phx-window-keydown={hide_modal(@on_cancel, @id)}
              phx-key="escape"
              phx-click-away={hide_modal(@on_cancel, @id)}
              class="hidden relative rounded-2xl bg-white p-14 shadow-lg shadow-zinc-700/10 ring-1 ring-gray-700/10 transition"
            >
              <div class="absolute top-6 right-5">
                <button
                  phx-click={hide_modal(@on_cancel, @id)}
                  type="button"
                  class="-m-3 flex-none p-3 opacity-20 hover:opacity-40"
                  aria-label="Close"
                >
                  x
                </button>
              </div>
              <div id={"#{@id}-content"}>
                <header :if={@title != []}>
                  <h1 id={"#{@id}-title"} class="text-lg font-semibold leading-8 text-zinc-800">
                    <%= render_slot(@title) %>
                  </h1>
                  <p :if={@subtitle != []} class="mt-2 text-sm leading-6 text-zinc-600">
                    <%= render_slot(@subtitle) %>
                  </p>
                </header>
                <%= render_slot(@inner_block) %>
                <div :if={@confirm != [] or @cancel != []} class="ml-6 mb-4 flex items-center gap-5">
                  <.button
                    :for={confirm <- @confirm}
                    id={"#{@id}-confirm"}
                    phx-click={@on_confirm}
                    phx-disable-with
                    class="py-2 px-3"
                  >
                    <%= render_slot(confirm) %>
                  </.button>
                  <.link
                    :for={cancel <- @cancel}
                    phx-click={hide_modal(@on_cancel, @id)}
                    class="text-sm font-semibold leading-6 text-zinc-900 hover:text-zinc-700"
                  >
                    <%= render_slot(cancel) %>
                  </.link>
                </div>
              </div>
            </.focus_wrap>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :rest, :global

  slot(:inner_block, required: true)

  def badge(assigns) do
    ~H"""
      <div><span class="text-xs font-semibold inline-block uppercase py-[3px] px-[5px] rounded bg-gray-100" {@rest}><%= render_slot(@inner_block) %></span></div>
    """
  end

  ## Forms

  @doc """
  Renders a for field select dropdown.
  ## Examples
    <.select form={f} field={:order_by} list={@sort_fields} selected={:inserted_at}>
  """

  attr :selected, :atom, required: true
  attr :form, :atom, required: true
  attr :field, :atom, required: true
  attr :list, :list, required: true

  slot(:inner_block, required: false)

  def select(assigns) do
    ~H"""
      <%= Form.select @form, @field, @list, selected: @selected, class: "
      my-1
      block
      w-full
      rounded-md
      border-gray-300
      shadow-sm
      focus:border-indigo-300 focus:ring focus:ring-indigo-200 focus:ring-opacity-50
    " %>
    """
  end

  @doc """
  Renders a text_input for a form field
  """

  attr :form, :atom, required: true
  attr :field, :atom, required: true
  attr :opts, :list, required: true

  slot(:inner_block, required: false)

  def text_input(assigns) do
    class = ~s(
      my-1
      block
      w-full
      rounded-md
      border-gray-300
      shadow-sm
      focus:border-indigo-300
      focus:ring
      focus:ring-indigo-200
      focus:ring-opacity-50)

    assigns = assign(assigns, :opts, assigns.opts ++ [class: class])

    ~H"""
      <%= Form.text_input @form, @field, @opts %>
    """
  end

  @doc """
  Renders a label for a form field
  """

  attr :form, :atom, required: true
  attr :field, :atom, required: true

  slot(:inner_block, required: false)

  def label(assigns) do
    ~H"""
      <%= Form.label @form, @field, class: "block text-gray-700 text-sm font-bold mb-2" %>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 50,
      transition:
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 50,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      transition: {"transition-all transform ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> show("##{id}-container")
    |> JS.focus_first(to: "##{id}-content")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-all transform ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> hide("##{id}-container")
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.pop_focus()
  end
end
