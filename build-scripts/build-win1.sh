echo $1

export HOME=/d/

git clone -b $1 --depth 1 https://github.com/flutter/flutter.git /d/flutter

flutter doctor -v
