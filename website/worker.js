// www.openarch.app goes to openarch.app, as it did on GitHub Pages. Every
// other request is answered with one of the site's files.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.hostname === "www.openarch.app") {
      url.hostname = "openarch.app";
      return Response.redirect(url.toString(), 301);
    }
    return env.ASSETS.fetch(request);
  },
};
