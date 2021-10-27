import Site from "discourse/models/site";
import { bind } from "discourse-common/utils/decorators";
import { schedule } from "@ember/runloop";

export default class StickyAvatars {
  stickyClass = "sticky-avatar";
  topicPostSelector = "#topic .post-stream .topic-post";
  intersectionObserver = null;
  direction = "⬇️";
  prevOffset = -1;

  static init(api) {
    new this(api).init();
  }

  constructor(api) {
    this.api = api;
  }

  init() {
    if (Site.currentProp("mobileView")) {
      return;
    }

    this.api.onAppEvent("topic:current-post-scrolled", this._handlePostNodes);
    this.api.onAppEvent("topic:scrolled", this._handleScroll);
    this.api.onAppEvent("page:topic-loaded", this._initIntersectionObserver);
    this.api.cleanupStream(this._clearIntersectionObserver);
  }

  @bind
  _handleScroll(offset) {
    if (offset <= 0) {
      this.direction = "⬇️";
      document
        .querySelectorAll(`${this.topicPostSelector}.${this.stickyClass}`)
        .forEach((node) => node.classList.remove(this.stickyClass));
    } else if (offset > this.prevOffset) {
      this.direction = "⬇️";
    } else {
      this.direction = "⬆️";
    }
    this.prevOffset = offset;
  }

  @bind
  _handlePostNodes() {
    this._clearIntersectionObserver();

    schedule("afterRender", () => {
      this._initIntersectionObserver();

      document.querySelectorAll(this.topicPostSelector).forEach((postNode) => {
        this.intersectionObserver.observe(postNode);

        const topicAvatarNode = postNode.querySelector(".topic-avatar");
        if (!topicAvatarNode || !postNode.querySelector("#post_1")) {
          return;
        }

        const topicMapNode = postNode.querySelector(".topic-map");
        if (!topicMapNode) {
          return;
        }
        topicAvatarNode.style.marginBottom = `${topicMapNode.clientHeight}px`;
      });
    });
  }

  @bind
  _initIntersectionObserver() {
    const headerHeight = document.querySelector(".d-header")?.clientHeight || 0;

    this.intersectionObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting || entry.intersectionRatio === 1) {
            entry.target.classList.remove(this.stickyClass);
            return;
          }

          const postContentHeight = entry.target.querySelector(".contents")
            ?.clientHeight;
          if (
            this.direction === "⬆️" ||
            postContentHeight > window.innerHeight - headerHeight
          ) {
            entry.target.classList.add(this.stickyClass);
          }
        });
      },
      { threshold: [0.0, 1.0], rootMargin: `-${headerHeight}px 0px 0px 0px` }
    );
  }

  @bind
  _clearIntersectionObserver() {
    this.intersectionObserver?.disconnect();
    this.intersectionObserver = null;
  }
}
