include(GNUInstallDirs)

if(NOT DEFINED PRISM_EXECUTABLE_PATH)
    set(PRISM_EXECUTABLE_PATH "prism")
endif()

if(PRISM_BUILD_FLATPAK)
    set(PRISM_SERVICE_START_COMMAND "ExecStart=flatpak run --command=prism ${PROJECT_FQDN}")
    set(PRISM_SERVICE_STOP_COMMAND "ExecStop=flatpak kill ${PROJECT_FQDN}")
else()
    set(PRISM_SERVICE_START_COMMAND "ExecStart=${PRISM_EXECUTABLE_PATH}")
    set(PRISM_SERVICE_STOP_COMMAND "")
endif()
