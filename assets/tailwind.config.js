module.exports = {
  purge: {
    enabled: process.env.NODE_ENV === "production",
    content: ["../lib/**/*.eex", "../lib/**/*.leex", "../lib/**/*_view.ex"],
    options: {
      whitelist: [/phx/, /nprogress/],
    },
  },
  content: [
    './js/**/*.js',
    '../lib/*_web.ex',
    '../lib/*_web/**/*.*ex',
  ],
  theme: {
    fontFamily: {
      sans: ["Inter", "system-ui"],
    },
  },
};
