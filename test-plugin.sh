#!/bin/bash

PLUGIN_DIR="/home/gongdewei/.config/nvm/versions/node/v22.20.0/lib/node_modules/openclaw/extensions/mattermost/"

cp -r . $PLUGIN_DIR
 
ls -l $PLUGIN_DIR 

DEBUG_MATTERMOST_MESSAGES=true openclaw gateway restart

