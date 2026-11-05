@echo off
rem Build the CUDA library and run the Java host on Windows.
rem Run this from "x64 Native Tools Command Prompt for VS 2022"
rem (needs: CUDA Toolkit, Visual Studio Build Tools with C++, JDK 22 or newer).
rem
rem Optional settings (set them before running build.bat):
rem   set JAVA=C:\path\to\jdk\bin\java.exe   Java 22+ to use (default: java on the PATH)
rem   set LOAD=100                            GPU load in percent (default: 50)
setlocal

if not defined JAVA set JAVA=java
if not defined LOAD set LOAD=50

"%JAVA%" -version >nul 2>&1 || (
  echo Java not found: %JAVA%
  echo Set it first, e.g.: set JAVA=C:\java\jdk-26\bin\java.exe
  exit /b 1
)

rem Optional CPU check of the MD5 step code (no GPU needed)
cl /nologo /O2 /EHsc /TP /DMD5_CPU_TEST md5search.cu /Fe:md5test.exe || goto :error
md5test.exe || goto :error

rem GPU library for the installed GPU (-arch=native). -Xptxas -v prints register use.
nvcc -O3 -arch=native -Xptxas -v -shared -o md5search.dll md5search.cu || goto :error

"%JAVA%" -Dmd5.load=%LOAD% --enable-native-access=ALL-UNNAMED Md5Search.java
goto :eof

:error
echo Build failed.
exit /b 1
