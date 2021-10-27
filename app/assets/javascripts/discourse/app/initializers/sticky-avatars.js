import { withPluginApi } from "discourse/lib/plugin-api";
import StickyAvatars from "discourse/lib/sticky-avatars";

export default {
  name: "sticky-avatars",

  initialize() {
    withPluginApi("0.11.1", (api) => {
      StickyAvatars.init(api);
    });
  },
};
