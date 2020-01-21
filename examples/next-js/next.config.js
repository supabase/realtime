require('dotenv').config()

module.exports = {
  env: {
    REALTIME_URL: process.env.REALTIME_URL,
    DB_HOST: process.env.DB_HOST,
    DB_NAME: process.env.DB_NAME,
    DB_USER: process.env.DB_USER,
    DB_PASSWORD: process.env.DB_PASSWORD,
    DB_PORT: process.env.DB_PORT,
  },
}
