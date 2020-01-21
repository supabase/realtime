
const { Pool, Client } = require('pg')

const pool = new Pool({
  host: process.env.DB_HOST,
  port: process.env.DB_PORT,
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
})


export default async (req, res) => {
  const {
    query: { table },
  } = req

  // don't do this ↓ in production
  const q = await pool.query(`SELECT * FROM ${table}`)
  return res.json(JSON.stringify(q.rows))
}
