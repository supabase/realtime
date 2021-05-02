const { Pool, Client } = require('pg')

const pool = new Pool({
  host: process.env.DB_HOST,
  port: process.env.DB_PORT,
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
})

export default async (req, res) => {
  const times = req.body.count
  const values = Array(times).fill("('hello world')").join(',')
  const text = `INSERT INTO stress(value) VALUES ${values} RETURNING id`
  // const startTime = Date.now()
  const q = await pool.query(text)
  // console.log({ times, exec: Date.now() - startTime }, q.rows)
  res.json(JSON.stringify(q.rows))
}
