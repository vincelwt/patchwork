// The wire types and the API client are shared with Desktop and live outside
// this folder, so Metro has to be told to watch them.
const path = require("node:path");
const { getDefaultConfig } = require("expo/metro-config");

const config = getDefaultConfig(__dirname);
config.watchFolders = [path.resolve(__dirname, "../client")];

module.exports = config;
