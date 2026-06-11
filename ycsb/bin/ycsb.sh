#!/bin/sh
#
# Licensed under the Apache License, Version 2.0 (the "License"); you
# may not use this file except in compliance with the License. You
# may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied. See the License for the specific language governing
# permissions and limitations under the License.
#
# Control Script for Fluss YCSB Benchmark

SCRIPT_DIR=$(dirname "$0" 2>/dev/null)
[ -z "$YCSB_HOME" ] && YCSB_HOME=$(cd "$SCRIPT_DIR/.." || exit; pwd)

CLASSPATH=

if [ -r "$YCSB_HOME/bin/setenv.sh" ]; then
  . "$YCSB_HOME/bin/setenv.sh"
fi

if [ -z "$JAVA_HOME" ]; then
  JAVA_PATH=$(which java 2>/dev/null)
  if [ "x$JAVA_PATH" != "x" ]; then
    JAVA_HOME=$(dirname "$(dirname "$JAVA_PATH" 2>/dev/null)")
  fi
fi

if [ -z "$JAVA_HOME" ]; then
  echo "[ERROR] Java executable not found. Exiting."
  exit 1
fi

if [ "load" = "$1" ]; then
  YCSB_COMMAND=-load
  YCSB_CLASS=site.ycsb.Client
elif [ "run" = "$1" ]; then
  YCSB_COMMAND=-t
  YCSB_CLASS=site.ycsb.Client
elif [ "shell" = "$1" ]; then
  YCSB_COMMAND=
  YCSB_CLASS=site.ycsb.CommandLine
else
  echo "[ERROR] Found unknown command '$1'"
  echo "[ERROR] Expected one of 'load', 'run', or 'shell'. Exiting."
  exit 1
fi

BINDING_LINE=$(grep "^$2:" "$YCSB_HOME/bin/bindings.properties" -m 1)

if [ -z "$BINDING_LINE" ]; then
  echo "[ERROR] The specified binding '$2' was not found. Exiting."
  exit 1
fi

BINDING_NAME=$(echo "$BINDING_LINE" | cut -d':' -f1)
BINDING_CLASS=$(echo "$BINDING_LINE" | cut -d':' -f2)

if [ -z "$CLASSPATH" ]; then
  CLASSPATH="$YCSB_HOME/conf"
else
  CLASSPATH="$CLASSPATH:$YCSB_HOME/conf"
fi

for f in "$YCSB_HOME"/lib/*.jar; do
  if [ -r "$f" ]; then
    CLASSPATH="$CLASSPATH:$f"
  fi
done

YCSB_ARGS=$(echo "$@" | cut -d' ' -f3-)

echo "$JAVA_HOME/bin/java $JAVA_OPTS -classpath $CLASSPATH $YCSB_CLASS $YCSB_COMMAND -db $BINDING_CLASS $YCSB_ARGS"

# shellcheck disable=SC2086
"$JAVA_HOME/bin/java" $JAVA_OPTS -classpath "$CLASSPATH" $YCSB_CLASS $YCSB_COMMAND -db $BINDING_CLASS $YCSB_ARGS
