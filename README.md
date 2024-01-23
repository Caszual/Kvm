# Kvm
Kvm (Karel Virtual Machine) is a blazingly fast interpreter for the Robot Karel language written in zig.

Kvm is only a bare compiler + interpreter library, to use it beyond just loading a karel-lang file and executing one function, see projects that incorporate Kvm like [PyKarel](https://github.com/C2Coder/PyKarel99) by [@C2Coder](https://github.com/C2Coder/).

## Building
You need to download the newest zig compiler. (currently 0.11.0)

To clone and build:
```sh
git clone https://github.com/Caszual/Kvm.git
cd Kvm/
zig build -Doptimize=ReleaseFast
```

After the build completes, to run the demo:
```sh
./zig-out/bin/Kvm
```

Or use it in your projects using the dynamic library (with a C api) in `./zig-out/lib/`

### Debug
To profile your Karel code or to debug the Vm build with `-Doptimize=Debug`

```sh
zig build -Doptimize=Debug
```

In this config the Kvm will print every bytecode instruction it executes together with its arguments.
**Warning**: This Config will slow down the Vm a lot and spam the output terminal.

## C API
As Kvm is currently semi-stable with new feature except bug-fixes being unlikely, I've compiled a guide for the current C API that the `libKvm.so` library exposes.
If you want a more exhaustive docs see the `src/main.zig` source file which exposes the API and has additional comments.

> note: All Kvm calls return and `KvmResult` enum defined in `src/kvm.zig` which can communicate if a lib call succeded or not. Can be ignored but useful for debugging.

After loading the library, the first thing you must do is `init()` the library. (If you don't `init()` Kvm, all other lib call return `not_initialized`)

```c
...

int init();

...

int main() {
    init();

    ...
```

or if you are loading Kvm dynamically

```c
int main() {
    // load kvm shared library
    void* kvm_handle = dlopen("./libKvm.so", RTLD_LAZY);
    assert(kvm_handle);

    int (*kvm_init)() = dlsym(kvm_handle, "init");

    // init kvm
    kvm_init();

    ...
```

next to run karel code inside Kvm you must:
- load the karel code
- load the city and karels inital position

> if you try to run Kvm without loading both the code and the world (city and karel), `state_not_valid` will be returned.

Karel code can be loaded using two ways, either from a file or directly from a string using `load_file(const char*)` and `load(const char*)` respectively.
If you call `load_file()` or `load()` after karel code has been already loaded, the old code gets overriden.

**important**: zig (and therefore Kvm) uses utf-8 for all its string literals and operations. All `const char*` passed into Kvm must also be utf-8. In C/C++ you can simply append `u8` to your string literals to make your strings also utf-8 encoded, eg. `const char* s = "hello"u8;`

```c
...

int load(const char* source);
int load_file(const char* path);

...

int main() {

    ...

    // load karel code

    int result = load(
    "TEST\n"u8
    "   STEP\n"u8
    "END\n"u8
    );

    // check karel code compilation was without errors (success = 0)
    assert(!result);

    // reload karel code (replaces code from previous load)

    result = load_file("test.kl"u8);
    assert(!result);

    ...
```

With `load_world(const uint8_t*, const uint32_t*)` it's the same altho a bit more complex because you need to send the city data and the karel data as two separed `unsigned int` (one 8 bit and second 32 bit) arrays.

The city array (first array) must be of size 20*20 or 400 and every byte represents one square (0 = empty; 1 to 8 = that number of flags; 255 = wall). The city array is then loaded as **row-major**.

The karel array is of size 5 and contains:
- at [0] - karel x
- at [1] - karel y 
- at [2] - karel direction
- at [3] - home x
- at [4] - home y

The Kvm coord system is 0 to 19 and starts at the bottom-left corner. Karel direction is between 0 and 3 and represents north, west, south and east respectively.

```c
#include <cstdint>

...

int load_world(const uint8_t*, const uint32_t*); 

...

int main() {

    ...

    uint8_t city_buf[400];

    // set your city data

    uint32_t karel_buf[5];

    karel_buf[0] = 0; // karel pos - starts at bottom-left corner
    karel_buf[1] = 0;

    karel_buf[2] = 0; // karel dir - north

    karel_buf[3] = 19;
    karel_buf[4] = 19; // karel home - placed at top-right corner

    load_world(city_buf, karel_buf);

    ...

```

Great, now you're ready to run your karel code at light speeds! To start interpreting, call the `run_symbol(const char*)` function with the name of the function that you want to run.

**important**: when interpreting in Kvm, the `run_symbol()` function doesn't return until the function is finished. To prevent freezes with complex or infinite karel code, you should run `run_symbol()` on a **different thread** from your main thread. All Kvm functions are thread-safe (either blocking like `load()` or run concurently with `run_symbol()` like `read_world()`)

It's particularly useful here to get the KvmResult int from the call as it reports karel code errors. (eg. `step_out_of_bounds`, `place_max_flags`, etc.)

```c

...

int run_symbol(const char*);

...

int main() {

    ...

    int result = run_symbol("TEST"u8); // don't forget the utf-8 encoding

    if (!result) {
        // success, code finished with no errors!
    } else if (result == 7) {
        // function not found in karel code
    } else if (result == 8) {
        // karel do a bonk
    } ...

    ...
```

Now we have successfully ran a karel simulation but we want to get our resulting city and karel position back! For that we use `read_world(uint8_t*, uint32_t*)`, it does exactly the same thing as `load_world()` but in the opposite direction. (in the same format)

```c

...

int read_world(uint8_t*, uint32_t*);

...

int main() {

    ...

    uint8_t city_buf[400];
    uint32_t karel_buf[5];    

    read_world(city_buf, karel_buf);

    printf("karel is at x %d and y %d\n", karel_buf[0], karel_buf[1]);

    ...
```

After you're done, don't forget to `deinit()` the library!

```c

...

void deinit();

...

int main() {

    ...

    deinit();
    return 0;
}

```

To see it all in action here's a full C sample

```c
#include <cstdint>
#include <stdio.h>

int init();
void deinit();

int load(const char*);
int load_file(const char*);

int load_world(const uint8_t*, const uint32_t*);
int read_world(uint8_t*, uint32_t*);

int run_symbol(const char*);

int main() {
    // initialize Kvm
    init();

    // load code and world

    int result = load_file("test.kl"u8);
    assert(!result);

    uint8_t city_buf[400] = {0};
    uint32_t karel_buf[5];

    karel_buf[0] = 0; // karel pos - starts at bottom-left corner
    karel_buf[1] = 0;

    karel_buf[2] = 0; // karel dir - north

    karel_buf[3] = 19;
    karel_buf[4] = 19; // karel home - placed at top-right corner

    load_world(city_buf, karel_buf);

    // interpret a karel function

    result = run_symbol("TEST"u8);

    if (!result) {
        printf("Karel completed successfully!");
    } else if (result == 7) {
        printf("Karel code function \"TEST\" not found!");
    } else if (result == 8) {
        // karel do a bonk
        printf("Karel do bonk.");
    }

    read_world(city_buf, karel_buf);

    printf("karel is at x %d and y %d\n", karel_buf[0], karel_buf[1]);

    // clean up Kvm
    deinit();

    return 0;
}

```

And that's the core API! 

There are also some extra util functions: (mostly for multi-threading, see `src/main.zig` for usage and docs)
- `short_circuit()` - interupt a running `run_symbol()` on another thread
- `status()` - returns a `success` or `in_progress` depending on if `run_symbol()` is running (on any thread)
- `dump_loaded()` - prints to stdout all loaded functions (symbols) and their internal bytecode addresses (funcs)
