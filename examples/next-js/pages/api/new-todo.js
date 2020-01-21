
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
  var randomTodo = faker.hacker.phrase()
  const text = 'INSERT INTO todos(details, user_id) VALUES($1, $2) RETURNING *'
  const values = [randomTodo, 1]
  const q = await pool.query(text, values)
  res.json(JSON.stringify(q.rows))
}
