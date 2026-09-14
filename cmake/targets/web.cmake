## @file
## @brief Rebuild web assets only when their sources, configuration, or dependencies change.
find_program(NPM npm REQUIRED)
find_program(NODE node REQUIRED)
set(NPM_INSTALL_FLAGS --ignore-scripts)
if(NPM_OFFLINE)
    list(APPEND NPM_INSTALL_FLAGS --offline)
endif()

# file(GENERATE) retains timestamps when the content is unchanged.
set(WEB_OPTIONS "${CMAKE_CURRENT_BINARY_DIR}/web-ui-options.txt")
file(GENERATE OUTPUT "${WEB_OPTIONS}" CONTENT "${NPM_INSTALL_FLAGS}\n${NPM}\n${NODE}\n")
set(NPM_STAMP "${CMAKE_SOURCE_DIR}/node_modules/.prism-dependencies")
add_custom_command(OUTPUT "${NPM_STAMP}"
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMAND "${NPM}" ci ${NPM_INSTALL_FLAGS}
        COMMAND "${CMAKE_COMMAND}" -E touch "${NPM_STAMP}"
        DEPENDS "${CMAKE_SOURCE_DIR}/package.json" "${CMAKE_SOURCE_DIR}/package-lock.json"
                "${WEB_OPTIONS}" "${NPM}" "${NODE}"
        COMMENT "Installing NPM dependencies"
        COMMAND_EXPAND_LISTS VERBATIM)

file(GLOB_RECURSE WEB_INPUTS CONFIGURE_DEPENDS "${PRISM_SOURCE_ASSETS_DIR}/common/assets/web/*")
set(WEB_MANIFEST "${CMAKE_CURRENT_BINARY_DIR}/web-ui-inputs.txt")
file(GENERATE OUTPUT "${WEB_MANIFEST}" CONTENT "${WEB_INPUTS}\n${PRISM_SOURCE_ASSETS_DIR}\n")
set(WEB_OUTPUTS)
foreach(page apps config index logout password pin troubleshooting welcome)
    list(APPEND WEB_OUTPUTS "${CMAKE_BINARY_DIR}/assets/web/${page}.html")
endforeach()
add_custom_command(OUTPUT ${WEB_OUTPUTS}
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMAND "${CMAKE_COMMAND}" -E env
                "PRISM_SOURCE_ASSETS_DIR=${PRISM_SOURCE_ASSETS_DIR}"
                "PRISM_ASSETS_DIR=${CMAKE_BINARY_DIR}" "${NPM}" run build-clean
        DEPENDS "${NPM_STAMP}" "${WEB_MANIFEST}" ${WEB_INPUTS}
                "${CMAKE_SOURCE_DIR}/vite.config.js"
        COMMENT "Building web assets"
        VERBATIM)
add_custom_target(web-ui ALL DEPENDS ${WEB_OUTPUTS} COMMENT "Checking web assets")
