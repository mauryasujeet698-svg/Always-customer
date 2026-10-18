// Load index.js first so initializeApp() runs before topicSync uses messaging.
module.exports = {
  ...require("./index"),
  ...require("./topicSync"),
};
