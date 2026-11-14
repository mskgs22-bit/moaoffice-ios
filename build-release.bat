@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo ===== 포켓 스캐너 Play 스토어 업로드용 빌드 (AAB) =====
echo.
if not exist android (echo [!] 먼저 build-android.bat 을 실행하세요. & pause & exit /b 1)
if not defined JAVA_HOME if exist "%ProgramFiles%\Android\Android Studio\jbr\bin\java.exe" set "JAVA_HOME=%ProgramFiles%\Android\Android Studio\jbr"
if not defined ANDROID_HOME set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
set "KS=%~dp0upload-key.jks"
echo 업로드 키 비밀번호를 입력하세요. (처음이면 새로 정할 비밀번호, 6자 이상)
echo  * 이 비밀번호와 upload-key.jks 파일은 잃어버리면 앱 업데이트가 어려워져요. 꼭 따로 보관하세요.
set /p "KPW=비밀번호: "
if not exist "%KS%" (
  echo 업로드 키를 새로 만들어요...
  "%JAVA_HOME%\bin\keytool.exe" -genkeypair -v -keystore "%KS%" -alias upload -keyalg RSA -keysize 2048 -validity 10000 -storepass "%KPW%" -keypass "%KPW%" -dname "CN=Pocket Scanner, O=Pocket Scanner, C=KR" || goto :err
)
call npm run libs || goto :err
call npx cap sync android || goto :err
> android\local.properties echo sdk.dir=%ANDROID_HOME:\=\\%
pushd android
call gradlew.bat bundleRelease -Pandroid.injected.signing.store.file="%KS%" -Pandroid.injected.signing.store.password="%KPW%" -Pandroid.injected.signing.key.alias=upload -Pandroid.injected.signing.key.password="%KPW%" || (popd & goto :err)
popd
set "KPW="
echo.
echo 완료! 이 파일을 Play Console에 업로드하세요:
echo %~dp0android\app\build\outputs\bundle\release\app-release.aab
explorer "%~dp0android\app\build\outputs\bundle\release"
pause
exit /b 0
:err
set "KPW="
echo.
echo [!] 오류가 났어요. 이 창을 캡처해서 Claude에게 보내주세요.
pause
exit /b 1
