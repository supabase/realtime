# SEL Data Collection: Specific Data Points for Music Games

## Overview

The music games platform collects **behavioral data**, **self-report data**, and **teacher observations** to measure social-emotional learning (SEL) outcomes aligned with the **CASEL framework**.

---

## CASEL Framework Alignment

The **Collaborative for Academic, Social, and Emotional Learning (CASEL)** defines five core competencies:

1. **Self-Awareness**: Understanding one's emotions, values, and strengths
2. **Self-Management**: Regulating emotions, thoughts, and behaviors
3. **Social Awareness**: Understanding and empathizing with others
4. **Relationship Skills**: Building and maintaining healthy relationships
5. **Responsible Decision-Making**: Making constructive choices about behavior and interactions

Our data collection maps to all five competencies.

---

## Data Collection Categories

### 1. Behavioral Data (Automatically Collected)

These are **objective, system-generated metrics** captured during gameplay without requiring student input.

#### Participation Metrics

**What we track**:
- **Session attendance**: Number of sessions attended vs. total sessions offered
- **Active participation time**: Minutes actively playing vs. total session time
- **Note play frequency**: Number of notes played per session
- **Turn completion rate**: Percentage of assigned turns where student played

**CASEL alignment**: Self-Management (engagement, persistence)

**Data structure**:
```json
{
  "student_id": "student-123",
  "session_id": "session-456",
  "game": "rhythm_circle",
  "timestamp": "2024-12-01T10:30:00Z",
  "participation": {
    "attendance": true,
    "active_time_seconds": 720,
    "total_session_seconds": 900,
    "notes_played": 45,
    "turns_assigned": 10,
    "turns_completed": 9,
    "participation_rate": 0.90
  }
}
```

**Why it matters**: Tracks engagement and self-regulation (staying focused, completing tasks).

---

#### Collaboration Metrics

**What we track**:
- **Timing accuracy**: How closely student plays in sync with group tempo (milliseconds off-beat)
- **Volume balance**: How well student adjusts volume to blend with group (dB variance from target)
- **Turn-taking compliance**: Whether student plays only on assigned beats (violations count)
- **Helping behaviors**: Instances where student assists a peer (detected via chat or teacher flag)

**CASEL alignment**: Relationship Skills (cooperation, teamwork), Social Awareness (listening to others)

**Data structure**:
```json
{
  "student_id": "student-123",
  "session_id": "session-456",
  "game": "rhythm_circle",
  "collaboration": {
    "timing_accuracy_ms": [12, 8, 15, 10, 9],  // Array of deviations per beat
    "avg_timing_accuracy_ms": 10.8,
    "volume_balance_db": [-2.1, -1.5, -3.0],  // Deviation from target blend
    "turn_violations": 1,  // Played on wrong beat
    "helped_peer": false,
    "responded_to_peer": true  // Played in response to another student
  }
}
```

**Why it matters**: Measures ability to coordinate with others, listen, and adjust behavior based on group needs.

---

#### Emotional Regulation Indicators

**What we track**:
- **Tempo adaptation speed**: How quickly student adjusts when teacher changes tempo (seconds to sync)
- **Error recovery**: Whether student continues playing after a mistake (resilience)
- **Frustration indicators**: Rapid repeated inputs, stopping play mid-session (potential frustration)
- **Persistence**: Continuing to play despite challenges (e.g., difficult rhythm patterns)

**CASEL alignment**: Self-Management (emotional regulation, resilience)

**Data structure**:
```json
{
  "student_id": "student-123",
  "session_id": "session-456",
  "emotional_regulation": {
    "tempo_changes": [
      {
        "old_bpm": 120,
        "new_bpm": 140,
        "adaptation_time_seconds": 3.2,
        "successful": true
      }
    ],
    "errors_made": 3,
    "continued_after_error": true,
    "frustration_indicators": {
      "rapid_inputs": 0,
      "mid_session_stops": 0
    },
    "persistence_score": 0.85  // Calculated: continued play / total opportunities
  }
}
```

**Why it matters**: Tracks self-regulation, resilience, and ability to manage frustration.

---

#### Creative Expression Metrics

**What we track**:
- **Note variety**: Number of unique notes played (in improvisation games)
- **Pattern originality**: How different student's patterns are from others (similarity score)
- **Risk-taking**: Playing outside suggested scale, trying new rhythms
- **Contribution diversity**: Variety of musical ideas contributed

**CASEL alignment**: Self-Awareness (recognizing strengths, expressing identity), Responsible Decision-Making (creative choices)

**Data structure**:
```json
{
  "student_id": "student-123",
  "session_id": "session-456",
  "game": "improvisation_jam",
  "creative_expression": {
    "unique_notes_played": 8,
    "total_notes_in_scale": 7,
    "played_outside_scale": 1,
    "pattern_originality_score": 0.72,  // 0-1, based on similarity to peers
    "risk_taking_instances": 2
  }
}
```

**Why it matters**: Measures self-expression, confidence, and willingness to take creative risks.

---

### 2. Self-Report Data (Student Input)

These are **subjective measures** where students reflect on their experience.

#### Post-Session Reflection Prompts

**Prompt 1: Emotional Check-In**
- **Question**: "How did you feel during this music session?"
- **Response type**: Emoji scale (😢 😐 🙂 😊 😄) or 1-5 Likert scale
- **CASEL alignment**: Self-Awareness (recognizing emotions)

**Data structure**:
```json
{
  "student_id": "student-123",
  "session_id": "session-456",
  "reflection_type": "emotional_checkin",
  "timestamp": "2024-12-01T10:45:00Z",
  "response": {
    "emotion_rating": 4,  // 1-5 scale
    "emotion_emoji": "😊"
  }
}
```

---

**Prompt 2: Collaboration Reflection**
- **Question**: "How well did you work with your classmates today?"
- **Response type**: Multiple choice or Likert scale
  - "I listened to others" (1-5)
  - "I helped someone" (Yes/No)
  - "I felt heard by others" (1-5)
- **CASEL alignment**: Relationship Skills, Social Awareness

**Data structure**:
```json
{
  "student_id": "student-123",
  "session_id": "session-456",
  "reflection_type": "collaboration",
  "response": {
    "listened_to_others": 5,
    "helped_someone": true,
    "felt_heard": 4,
    "collaboration_quality": "great"  // "poor", "okay", "good", "great"
  }
}
```

---

**Prompt 3: Goal Setting**
- **Question**: "What do you want to get better at next time?"
- **Response type**: Multiple choice
  - "Playing in rhythm"
  - "Listening to others"
  - "Trying new ideas"
  - "Staying focused"
  - Other (free text)
- **CASEL alignment**: Self-Awareness (recognizing areas for growth), Responsible Decision-Making (goal setting)

**Data structure**:
```json
{
  "student_id": "student-123",
  "session_id": "session-456",
  "reflection_type": "goal_setting",
  "response": {
    "goal_selected": "listening_to_others",
    "custom_goal": null
  }
}
```

---

**Prompt 4: Free Reflection** (Optional)
- **Question**: "What did you enjoy most? What was challenging?"
- **Response type**: Free text (short answer)
- **CASEL alignment**: Self-Awareness (reflection), Responsible Decision-Making (evaluating experiences)

**Data structure**:
```json
{
  "student_id": "student-123",
  "session_id": "session-456",
  "reflection_type": "free_response",
  "response": {
    "enjoyed_most": "Playing the drums with my friends!",
    "found_challenging": "Keeping up when the tempo got faster"
  }
}
```

---

### 3. Teacher Observations (Manual Input)

These are **qualitative assessments** from the teacher during or after sessions.

#### Observation Categories

**Social Interactions**:
- **Question**: "Did you observe any notable social interactions?"
- **Response type**: Checkboxes + notes
  - Student helped a peer
  - Student encouraged others
  - Student resolved a conflict
  - Student showed leadership
  - Notes (free text)

**CASEL alignment**: Relationship Skills, Social Awareness

**Data structure**:
```json
{
  "teacher_id": "teacher-789",
  "session_id": "session-456",
  "observation_type": "social_interactions",
  "timestamp": "2024-12-01T10:50:00Z",
  "students_observed": ["student-123", "student-456"],
  "observations": {
    "helped_peer": true,
    "encouraged_others": false,
    "resolved_conflict": false,
    "showed_leadership": true,
    "notes": "Student 123 helped student 456 find the right beat"
  }
}
```

---

**Emotional Regulation**:
- **Question**: "Did you observe any students struggling with emotional regulation?"
- **Response type**: Checkboxes + notes
  - Student showed frustration
  - Student recovered from mistake well
  - Student needed support
  - Notes (free text)

**CASEL alignment**: Self-Management

**Data structure**:
```json
{
  "teacher_id": "teacher-789",
  "session_id": "session-456",
  "observation_type": "emotional_regulation",
  "students_observed": ["student-789"],
  "observations": {
    "showed_frustration": true,
    "recovered_well": true,
    "needed_support": false,
    "notes": "Initially frustrated with tempo change, but adapted quickly"
  }
}
```

---

**Engagement & Participation**:
- **Question**: "Overall engagement level for this session?"
- **Response type**: Likert scale (1-5) + notes
  - Whole class engagement
  - Individual student engagement (optional)
  - Notes (free text)

**CASEL alignment**: Self-Management

**Data structure**:
```json
{
  "teacher_id": "teacher-789",
  "session_id": "session-456",
  "observation_type": "engagement",
  "whole_class_engagement": 4,
  "individual_observations": [
    {
      "student_id": "student-123",
      "engagement_level": 5,
      "notes": "Highly engaged, led the group"
    }
  ]
}
```

---

## Aggregated Metrics & Dashboards

### Student-Level Dashboard

**For each student, aggregate data across sessions**:

#### SEL Growth Over Time
- **Participation trend**: Line graph showing participation rate over time
- **Collaboration score**: Average timing accuracy, turn-taking compliance
- **Emotional regulation**: Persistence score, error recovery rate
- **Creative expression**: Pattern originality, note variety

**Example visualization**:
```
Participation Rate (Last 10 Sessions)
100% |     ●
     |    ●
 80% |   ●     ●
     |  ●       ●
 60% | ●
     |
     +------------------
      1  2  3  4  5  6
```

---

#### CASEL Competency Scores

**For each CASEL competency, calculate a composite score (0-100)**:

1. **Self-Awareness** (0-100)
   - Emotional check-in ratings (avg)
   - Goal-setting engagement (% of sessions)
   - Free reflection depth (qualitative score)

2. **Self-Management** (0-100)
   - Participation rate (%)
   - Persistence score (%)
   - Error recovery rate (%)
   - Teacher observations (emotional regulation)

3. **Social Awareness** (0-100)
   - "Listened to others" self-rating (avg)
   - Volume balance (how well student blends)
   - Teacher observations (social interactions)

4. **Relationship Skills** (0-100)
   - "Helped someone" frequency (%)
   - "Felt heard" self-rating (avg)
   - Collaboration quality self-rating (avg)
   - Teacher observations (helping behaviors)

5. **Responsible Decision-Making** (0-100)
   - Goal achievement (did student improve on stated goal?)
   - Creative risk-taking (pattern originality)
   - Turn-taking compliance (%)

**Example dashboard**:
```
CASEL Competency Scores (Student 123)

Self-Awareness        ████████░░ 80
Self-Management       ██████████ 95
Social Awareness      ███████░░░ 70
Relationship Skills   █████████░ 90
Responsible Decisions ████████░░ 85
```

---

### Class-Level Dashboard

**For teachers to see whole-class trends**:

#### Class Engagement
- Average participation rate
- Number of students actively engaged
- Trend over time

#### Collaboration Quality
- Average timing accuracy (class)
- Turn-taking compliance (class)
- Helping behaviors (frequency)

#### SEL Growth
- Class average for each CASEL competency
- Students showing improvement
- Students needing support

**Example visualization**:
```
Class Collaboration Quality

Timing Accuracy (avg):  12ms ✓ (target: <20ms)
Turn-Taking Compliance: 92%  ✓ (target: >85%)
Helping Behaviors:      15   ✓ (increased from 10 last session)

Students Showing Strong Collaboration:
- Student 123 (95% compliance, helped 3 peers)
- Student 456 (avg timing: 8ms)

Students Needing Support:
- Student 789 (60% compliance, consider 1-on-1 check-in)
```

---

## Privacy & Ethics

### Data Privacy Principles

1. **Student data is owned by the school/teacher**, not the platform
2. **No personally identifiable information (PII)** is shared with third parties
3. **Data is anonymized** for research purposes (with consent)
4. **FERPA and COPPA compliant** (US education privacy laws)
5. **Parents can request data deletion** at any time

### Ethical Considerations

1. **Avoid labeling students**: Data is for growth, not judgment
2. **Focus on trends, not single data points**: One bad session doesn't define a student
3. **Teacher discretion**: Teachers decide how to use data (not automated interventions)
4. **Positive framing**: Dashboard emphasizes growth and strengths, not deficits

---

## Data Collection Implementation

### Backend (Developer #1: Supabase Realtime)

**Database schema** (PostgreSQL):

```sql
-- Behavioral data
CREATE TABLE participation_events (
  id UUID PRIMARY KEY,
  student_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  game TEXT NOT NULL,
  timestamp TIMESTAMPTZ NOT NULL,
  event_type TEXT NOT NULL,  -- 'note_played', 'turn_completed', etc.
  event_data JSONB
);

-- Self-report data
CREATE TABLE student_reflections (
  id UUID PRIMARY KEY,
  student_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  reflection_type TEXT NOT NULL,  -- 'emotional_checkin', 'collaboration', etc.
  timestamp TIMESTAMPTZ NOT NULL,
  response JSONB
);

-- Teacher observations
CREATE TABLE teacher_observations (
  id UUID PRIMARY KEY,
  teacher_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  observation_type TEXT NOT NULL,
  students_observed TEXT[],
  timestamp TIMESTAMPTZ NOT NULL,
  observations JSONB
);

-- Aggregated metrics (materialized view)
CREATE MATERIALIZED VIEW student_sel_scores AS
SELECT
  student_id,
  AVG(participation_rate) as avg_participation,
  AVG(timing_accuracy_ms) as avg_timing_accuracy,
  AVG(persistence_score) as avg_persistence,
  -- ... other aggregations
FROM participation_events
GROUP BY student_id;
```

**API endpoints**:
```
POST /api/events/participation
POST /api/reflections
POST /api/observations
GET  /api/students/:id/sel-scores
GET  /api/sessions/:id/analytics
```

---

### Frontend (Project 2)

**Reflection UI** (shown after each session):

```jsx
// Post-session reflection modal
<ReflectionModal>
  <h2>How did you feel today?</h2>
  <EmojiScale
    options={['😢', '😐', '🙂', '😊', '😄']}
    onSelect={(rating) => submitReflection('emotional_checkin', { rating })}
  />
  
  <h2>How well did you work with others?</h2>
  <LikertScale
    question="I listened to others"
    onSelect={(rating) => submitReflection('collaboration', { listened: rating })}
  />
  
  <h2>What do you want to improve next time?</h2>
  <MultipleChoice
    options={['Playing in rhythm', 'Listening to others', 'Trying new ideas']}
    onSelect={(goal) => submitReflection('goal_setting', { goal })}
  />
</ReflectionModal>
```

**Teacher dashboard**:

```jsx
// Class-level SEL dashboard
<TeacherDashboard>
  <ClassEngagement sessionId={sessionId} />
  <CollaborationMetrics sessionId={sessionId} />
  <SELCompetencyScores classId={classId} />
  <StudentSpotlight students={needingSupport} />
</TeacherDashboard>
```

---

## The Bottom Line

**We collect three types of SEL data**:

1. **Behavioral** (automatic): Participation, collaboration, emotional regulation, creative expression
2. **Self-report** (student input): Emotional check-ins, collaboration reflections, goal setting
3. **Teacher observations** (manual): Social interactions, emotional regulation, engagement

**All data maps to CASEL's five competencies**:
- Self-Awareness
- Self-Management
- Social Awareness
- Relationship Skills
- Responsible Decision-Making

**The data enables**:
- Student growth tracking (individual dashboards)
- Teacher insights (class-level trends)
- Research validation (efficacy studies)
- SEL program alignment (CASEL framework)

**Privacy-first approach**:
- FERPA/COPPA compliant
- Student data owned by schools
- No third-party sharing
- Parent opt-out available

This is **measurable, actionable SEL data** that demonstrates the educational value of collaborative music-making.
