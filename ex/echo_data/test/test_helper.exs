# The NIF-backed tests (tag :nif) run only when the NIF is loaded; `make -C ex test` builds it and
# runs the suite twice — with the NIF, and again with ECHO_DATA_NATIVE=0 (pure).
ExUnit.start(exclude: if(EchoData.Native.loaded?(), do: [], else: [:nif]))
