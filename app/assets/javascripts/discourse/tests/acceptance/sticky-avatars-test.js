import { module, test } from "qunit";
import { find, visit } from "@ember/test-helpers";
import { setupApplicationTest } from "ember-qunit";

module("Acceptance | sticky avatars", function (hooks) {
  setupApplicationTest(hooks);

  test("Adds sticky avatars when scrolling up", async function (assert) {
    await visit("/t/internationalization-localization/280");
    document.getElementById("ember-testing-container").scrollTop = 800;
    document.getElementById("ember-testing-container").scrollTop = 700;

    assert.ok(
      find("#post_3").parentElement.classList.contains("sticky-avatar"),
      "Sticky avatar is applied"
    );
  });
});
