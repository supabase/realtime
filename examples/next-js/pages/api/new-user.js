
const { Pool, Client } = require('pg')
var faker = require('faker')

const pool = new Pool({
    host: process.env.DB_HOST,
    port: process.env.DB_PORT,
    database: process.env.DB_NAME,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
})

export default async (req, res) => {
  var randomName = faker.name.findName()
  const text = 'INSERT INTO users(name) VALUES($1) RETURNING *'
  const values = [randomName]
  const q = await pool.query(text, values)
  res.json(JSON.stringify(q.rows))
}
