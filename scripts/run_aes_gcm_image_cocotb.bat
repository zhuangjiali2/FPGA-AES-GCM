@echo off
setlocal enabledelayedexpansion

set PYTHON=E:\conda\envs\rag_env\python.exe
set MODELSIM=E:\modelsim\win64pe
set ROOT=%~dp0..
set BUILD=%ROOT%\result\modelsim_aes_gcm_image_cocotb

if exist "%BUILD%\work" rd /s /q "%BUILD%\work"
if not exist "%BUILD%" mkdir "%BUILD%"

for %%P in ("%PYTHON%") do set PYTHON_HOME=%%~dpP
set PATH=%MODELSIM%;%PYTHON_HOME%;%PYTHON_HOME%Library\bin;%PATH%
set MODULE=gcm_image_test
set TOPLEVEL=aes_gcm_stream_engine
set TOPLEVEL_LANG=verilog
set COCOTB_TEST_MODULES=gcm_image_test
set COCOTB_TOPLEVEL=aes_gcm_stream_engine
set COCOTB_TOPLEVEL_LANG=verilog
set PYTHONPATH=%ROOT%\sim
set PYGPI_PYTHON_BIN=%PYTHON%
set COCOTB_RESULTS_FILE=%BUILD%\results.xml

for /f "delims=" %%i in ('%PYTHON% -c "from cocotb.config import lib_name_path; print(lib_name_path('vpi', 'questa'))"') do set PLI=%%i

set SOURCES=
for /f "usebackq delims=" %%F in ("%ROOT%\scripts\filelist.txt") do (
    set SOURCES=!SOURCES! %ROOT%\%%F
)

pushd "%BUILD%"
"%MODELSIM%\vlib.exe" work
"%MODELSIM%\vlog.exe" -work work %SOURCES% > "%BUILD%\vlog.log" 2>&1
"%MODELSIM%\vsim.exe" -batch -pli "%PLI%" -do "run -all; quit -f" work.aes_gcm_stream_engine > "%BUILD%\vsim.log" 2>&1
type "%BUILD%\vsim.log"
popd
endlocal
