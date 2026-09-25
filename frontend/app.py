# frontend/app.py
import streamlit as st
from datetime import datetime
from _scripts.core.database import DatabaseManager

@st.cache_resource
def get_db_manager():
    return DatabaseManager()

db_manager = get_db_manager()

st.set_page_config(page_title="Clinical Genomics LIMS", layout="wide")
st.title("Clinical LIMS and NGS Variant Management Hub")

# Define tab titles once, up top, so callbacks and widgets can both reference it
tab_titles = ["1. Register Patient Only", "2. Order Test and Accession Sample", "3. Master Clinical Query"]

# 1. INITIALIZE SESSION STATE MEMORY KEYS
if "active_tab" not in st.session_state:
    st.session_state.active_tab = tab_titles[0]
if "search_results" not in st.session_state:
    st.session_state.search_results = None
if "search_executed" not in st.session_state:
    st.session_state.search_executed = False
if "mrn_lookup_results" not in st.session_state:
    st.session_state.mrn_lookup_results = None


def generate_next_patient_id(cursor) -> str:
    """Generates the next patient_id as 'YYYYMMDD-00001', scoped to today's date."""
    date_prefix = datetime.now().strftime("%Y%m%d")
    cursor.execute("SELECT COUNT(*) FROM patients WHERE patient_id LIKE %s;", (f"{date_prefix}-%",))
    next_serial = cursor.fetchone()[0] + 1
    return f"{date_prefix}-{next_serial:05d}"


# Callback: fired on Enter in the tab-3 MRN search box. Clears the name box
# so the two searches can't conflict.
def on_search_mrn_change():
    st.session_state.search_name_field = ""
    st.session_state.active_tab = tab_titles[2]
    st.session_state.search_executed = True


# Callback: fired on Enter in the tab-3 name search box. Clears the MRN box
# so the two searches can't conflict.
def on_search_name_change():
    st.session_state.search_mrn_field = ""
    st.session_state.active_tab = tab_titles[2]
    st.session_state.search_executed = True


# Callback: fired as the MRN field in tab 2 changes. Looks up any patients
# whose MRN starts with what's typed so far and shows their MRN, name, and
# age live.
def lookup_patient_by_mrn():
    typed = st.session_state.get("mrn_input_field", "").strip()
    if not typed:
        st.session_state.mrn_lookup_results = None
        return
    try:
        conn = db_manager.get_connection()
        cursor = conn.cursor()
        # SQL Server syntax: TOP goes right after SELECT, not a trailing LIMIT.
        cursor.execute(
            "SELECT TOP 10 mrn, name, age FROM patients WHERE mrn LIKE %s ORDER BY mrn;",
            (f"{typed}%",)
        )
        st.session_state.mrn_lookup_results = cursor.fetchall()
        conn.close()
    except Exception as e:
        st.session_state.mrn_lookup_results = None
        st.error(f"Lookup error: {e}")


# 2. RENDER NAVIGATION
# st.tabs() has no persistent selection state -- it always resets to the first
# tab on rerun, which is why pressing Enter in a search box used to kick you
# back to tab 1. A key-bound st.radio is driven by st.session_state, so a
# callback can move the "active tab" and it will actually stick across reruns.
st.radio(
    "Navigation",
    tab_titles,
    horizontal=True,
    label_visibility="collapsed",
    key="active_tab",
)

st.divider()

# --- SECTION 1: STANDALONE PATIENT REGISTRATION ---
if st.session_state.active_tab == tab_titles[0]:
    st.header("Register Patient Profile")
    with st.form("standalone_patient_form", clear_on_submit=True):
        mrn = st.text_input("Medical Record Number (MRN) *").strip()
        name = st.text_input("Full Patient Name *")
        age = st.number_input("Age", min_value=0, max_value=120, value=30, step=1)
        sex = st.selectbox("Biological Sex", ["Male", "Female", "Other"])

        submit_btn = st.form_submit_button("Save Patient Profile Only")

        if submit_btn:
            if not mrn or not name:
                st.error("Error: MRN and Full Name are strictly required fields.")
            else:
                try:
                    conn = db_manager.get_connection()
                    cursor = conn.cursor()

                    cursor.execute("SELECT COUNT(*) FROM patients WHERE mrn = %s;", (mrn,))
                    if cursor.fetchone()[0] > 0:
                        st.error(f"Error: A patient profile with MRN '{mrn}' already exists.")
                    else:
                        new_patient_id = generate_next_patient_id(cursor)
                        cursor.execute(
                            "INSERT INTO patients (patient_id, mrn, name, age, sex) VALUES (%s, %s, %s, %s, %s);",
                            (new_patient_id, mrn, name, int(age), sex)
                        )
                        conn.commit()
                        st.success(f"Success: Patient Profile for {name} saved successfully!")
                        st.info(f"Assigned Patient ID: {new_patient_id}")
                    conn.close()
                except Exception as e:
                    st.error(f"Database error: {e}")

# --- SECTION 2: SAMPLE ACCESSION AND ASSAY ORDERING ---
if st.session_state.active_tab == tab_titles[1]:
    st.header("Specimen Accessioning and Test Requisition")

    st.markdown("### 1. Patient Demographics")
    mrn_input = st.text_input(
        "Patient MRN *",
        key="mrn_input_field",
        on_change=lookup_patient_by_mrn,
    ).strip()

    # Live match display: shows MRN, name, and age for any existing patients
    # matching what's typed so far. Updates whenever the field's on_change fires.
    if st.session_state.mrn_lookup_results is not None:
        if len(st.session_state.mrn_lookup_results) > 0:
            st.caption("Matching patients:")
            for match_mrn, match_name, match_age in st.session_state.mrn_lookup_results:
                st.caption(f"• {match_mrn} — {match_name}, age {match_age}")
        else:
            st.caption("No matching patients found.")

    is_new_patient = st.checkbox("New Patient? (Check this to fill demographics if MRN doesn't exist yet)")

    name_input, age_input, sex_input = "", 30, "Male"
    if is_new_patient:
        c1, c2, c3 = st.columns(3)
        with c1: name_input = st.text_input("Full Patient Name")
        with c2: age_input = st.number_input("Age Input", min_value=0, max_value=120, value=30)
        with c3: sex_input = st.selectbox("Sex Input", ["Male", "Female", "Other"])

    st.markdown("---")
    st.markdown("### 2. Assay Details")
    test_code = st.selectbox("Select Target Assay / Test Code", ["Hereditary_Cancer", "Cardio_Risk", "Whole_Exome"])

    submit_order = st.button("Generate Accession and Place Order")

    if submit_order:
        if not mrn_input:
            st.error("Error: A valid MRN is required to process an order.")
        else:
            try:
                conn = db_manager.get_connection()
                cursor = conn.cursor()

                # Look up the patient's actual patient_id -- samples/orders key
                # off patient_id, not mrn, so we need the real value, not just
                # a yes/no existence check.
                cursor.execute("SELECT patient_id FROM patients WHERE mrn = %s;", (mrn_input,))
                existing_row = cursor.fetchone()

                if existing_row is None:
                    if is_new_patient and name_input:
                        target_patient_id = generate_next_patient_id(cursor)
                        cursor.execute(
                            "INSERT INTO patients (patient_id, mrn, name, age, sex) VALUES (%s, %s, %s, %s, %s);",
                            (target_patient_id, mrn_input, name_input, int(age_input), sex_input)
                        )
                        st.info(f"System: Automatically created missing patient profile for '{name_input}'.")
                    else:
                        st.error("Error: This MRN does not exist. Check 'New Patient' below to create them on the fly.")
                        conn.close()
                        st.stop()
                else:
                    target_patient_id = existing_row[0]

                date_prefix = datetime.now().strftime("%Y%m%d")
                cursor.execute("SELECT COUNT(*) FROM samples WHERE sample_id LIKE %s;", (f"SAM-{date_prefix}%",))
                next_sample_serial = cursor.fetchone()[0] + 1
                generated_sample_id = f"SAM-{date_prefix}-{next_sample_serial:05d}"

                cursor.execute(
                    "INSERT INTO samples (sample_id, patient_id) VALUES (%s, %s);",
                    (generated_sample_id, target_patient_id)
                )

                # test_order_id is a computed column derived from the IDENTITY
                # order_id, so we can't insert into it directly -- OUTPUT hands
                # back the values SQL Server generated for the new row.
                cursor.execute(
                    """
                    INSERT INTO orders (sample_id, test_code)
                    OUTPUT INSERTED.order_id, INSERTED.test_order_id
                    VALUES (%s, %s);
                    """,
                    (generated_sample_id, test_code)
                )
                new_order_id, generated_order_id = cursor.fetchone()

                conn.commit()
                st.success("Success: Accessioning Complete and Order Placed!")
                st.metric(label="Assigned Sample ID Anchor", value=generated_sample_id)
                st.info(f"Generated Test Order ID: {generated_order_id}")

                conn.close()
            except Exception as e:
                st.error(f"Workflow processing error: {e}")

# --- SECTION 3: MASTER INFORMATICS LOOKUP ---
if st.session_state.active_tab == tab_titles[2]:
    st.header("Master Patient Informatics Search")

    col1, col2 = st.columns(2)
    with col1:
        search_mrn = st.text_input(
            "Search by Exact Patient MRN",
            key="search_mrn_field",
            on_change=on_search_mrn_change,
        ).strip()
    with col2:
        search_name = st.text_input(
            "Search by Partial Patient Name",
            key="search_name_field",
            on_change=on_search_name_change,
        ).strip()

    # Run the database lookup query if state triggers it
    if st.session_state.search_executed and (search_mrn or search_name):
        try:
            conn = db_manager.get_connection()
            cursor = conn.cursor()

            sql = """
                SELECT p.mrn, p.name, s.sample_id, o.test_order_id, o.test_code, o.status,
                       v.chrom, v.start_pos, v.classification
                FROM patients p
                LEFT JOIN samples s ON p.patient_id = s.patient_id
                LEFT JOIN orders o ON s.sample_id = o.sample_id
                LEFT JOIN variants v ON o.order_id = v.order_id
            """

            if search_mrn:
                sql += " WHERE p.mrn = %s;"
                cursor.execute(sql, (search_mrn,))
            else:
                sql += " WHERE p.name LIKE %s;"
                cursor.execute(sql, (f"%{search_name}%",))

            rows = cursor.fetchall()

            if rows:
                data_list = []
                for row in rows:
                    data_list.append({
                        "MRN": row[0],
                        "Patient Name": row[1],
                        "Sample ID": row[2] if row[2] else "No Samples registered",
                        "Order ID": row[3] if row[3] else "No Orders",
                        "Test Assay": row[4] if row[4] else "N/A",
                        "Order Status": row[5] if row[5] else "N/A",
                        "Variant Mutation": f"chr{row[6]}:{row[7]}" if row[6] else "N/A",
                        "Classification": row[8] if row[8] else "N/A"
                    })
                st.session_state.search_results = data_list
            else:
                st.session_state.search_results = []

            conn.close()
        except Exception as e:
            st.error(f"Query execution error: {e}")
        finally:
            # Reset workflow execution gate
            st.session_state.search_executed = False

    # Render results from memory context if they exist
    if st.session_state.search_results is not None:
        if len(st.session_state.search_results) > 0:
            st.write("Query Results found:")
            st.dataframe(st.session_state.search_results, use_container_width=True)
        else:
            st.warning("Warning: No records found matching those parameters.")
    else:
        st.info("Please enter search criteria and execute the search.")