# Contributing
Read our contribution guide in our organization level
[docs](https://docs.lizardbyte.dev/latest/developers/contributing.html).

## Recommended Tools

| Tool                                                                                                                                                                           | Description                                                             |
|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------|
| <a href="https://www.jetbrains.com/clion/"><img src="https://resources.jetbrains.com/storage/products/company/brand/logos/CLion_icon.svg" width="30" height="30"></a><br>CLion | Recommended IDE for C and C++ development. Free for non-commercial use. |

## Project Patterns

### Web UI
* The Web UI uses [Vite](https://vitejs.dev) as its build system.
* The HTML pages used by the Web UI are found in `./src_assets/common/assets/web`.
* [EJS](https://www.npmjs.com/package/vite-plugin-ejs) is used as a templating system for the pages
  (check `template_header.html` and `template_header_main.html`).
* The Style System is provided by [Bootstrap](https://getbootstrap.com).
* Icons are provided by [Lucide](https://lucide.dev) and [Simple Icons](https://simpleicons.org).
* The JS framework used by the more interactive pages is [Vue.js](https://vuejs.org).

#### Building

@tabs{
  @tab{CMake | ```bash
    cmake -B cmake-build-prism -G Ninja -S . --target web-ui
    ninja -C cmake-build-prism web-ui
    ```}
  @tab{Manual | ```bash
    npm run dev
    ```}
}

### Localization
Prism's maintained source locale is `en` (English). Do not edit `en-US`, other English variants, or any translated
locale when adding or changing user-facing text.

#### Translation Basics
* The brand names *LizardByte*, *Sunshine*, and *Prism* should never be translated.
* Other brand names should never be translated. Examples include *AMD*, *Intel*, and *NVIDIA*.

#### Extraction

##### Web UI
Prism uses [Vue I18n](https://vue-i18n.intlify.dev) for localizing the UI.
The following is a simple example of how to use it.

* Add the string to the `./src_assets/common/assets/web/public/assets/locale/en.json` file, in English.
  ```json
  {
   "index": {
     "welcome": "Hello, Prism!"
   }
  }
  ```

  > [!NOTE]
  > The JSON keys should be sorted alphabetically. You can use [jsonabc](https://novicelab.org/jsonabc)
  > to sort the keys.

  > [!IMPORTANT]
  > Only add strings to the *en.json* file. Do not modify any other locale file.

* Use the string in the Vue component.
  ```html
  <template>
    <div>
      <p>{{ $t('index.welcome') }}</p>
    </div>
  </template>
  ```

  > [!TIP]
  > More formatting examples can be found in the
  > [Vue I18n guide](https://kazupon.github.io/vue-i18n/guide/formatting.html).

##### C++

There should be minimal cases where strings need to be extracted from C++ source code; however it may be necessary in
some situations. For example the system tray icon could be localized as it is user interfacing.

* Wrap the string to be extracted in a function as shown.
  ```cpp
  #include <boost/locale.hpp>
  #include <string>

  std::string msg = boost::locale::translate("Hello world!");
  ```

> [!TIP]
> More examples can be found in the documentation for
> [boost locale](https://www.boost.org/doc/libs/1_70_0/libs/locale/doc/html/messages_formatting.html).

Localization extraction is a manual maintainer task; there is no localization workflow in this repository.
Contributors should not include generated template or compiled locale files in pull requests. To validate extraction
locally, install Python and uv, then install the dependencies from the Prism `pyproject.toml`.

```bash
uv sync --locked
```

Additionally, [xgettext](https://www.gnu.org/software/gettext) must be installed.

* Extract, initialize, and update
  ```bash
  uv run --locked --no-sync lb-localize --root-dir . --extract --init --update
  ```

* Compile
  ```bash
  uv run --locked --no-sync lb-localize --root-dir . --compile
  ```

### Testing

#### Clang Format
Source code is tested against the `.clang-format` file for linting errors.

From the repository root, apply clang-format locally with the installed lizardbyte-common script. This will modify
files in place.

```bash
uv sync --locked
uv run --locked --no-sync lb-update-clang-format
```

#### Unit Testing
Prism uses [Google Test](https://github.com/google/googletest) for unit testing. Google Test is included in the
repo as a submodule. The test sources are located in the `./tests` directory.

The tests need to be compiled into an executable, and then run. The tests are built using the normal build process, but
can be disabled by setting the `BUILD_TESTS` CMake option to `OFF`.

To run the tests, execute the following command.

```bash
./cmake-build-prism/tests/test_prism
```

To see all available options, run the tests with the `--help` flag.

```bash
./cmake-build-prism/tests/test_prism --help
```

> [!TIP]
> See the googletest [FAQ](https://google.github.io/googletest/faq.html) for more information on how to use Google Test.

The required `Linux / Build and test` GitHub check runs the complete Google Test suite under Xvfb. It uses
[gcovr](https://www.gcovr.com) to generate coverage and uploads coverage and test results to
[Codecov](https://about.codecov.io) for pull requests and commits on `master`.

Codecov will fail a PR if the total coverage is reduced too much, or if not enough of the diff is covered by tests.
In some cases, the code cannot be covered when running the tests inside of GitHub runners. For example, any test that
needs access to the GPU will not be able to run. In these cases, the coverage can be omitted by adding comments to the
code. See the [gcovr documentation](https://gcovr.com/en/stable/guide/exclusion-markers.html#exclusion-markers) for
more information.

Even if your changes cannot be covered in the CI, we still encourage you to write the tests for them. This will allow
maintainers to run the tests locally.

<div class="section_buttons">

| Previous                |                                                         Next |
|:------------------------|-------------------------------------------------------------:|
| [Building](building.md) | [Source Code](../third-party/doxyconfig/docs/source_code.md) |

</div>

<details style="display: none;">
  <summary></summary>
  [TOC]
</details>
