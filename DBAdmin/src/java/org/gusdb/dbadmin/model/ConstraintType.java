
package org.gusdb.dbadmin.model;


/**
 * @author msaffitz
 * @version $Revision$ $Date$
 */
public class ConstraintType {

    public static final ConstraintType UNIQUE = new ConstraintType("UNIQUE"); 
    public static final ConstraintType FOREIGN_KEY = new ConstraintType("FOREIGN KEY"); 
    public static final ConstraintType PRIMARY_KEY = new ConstraintType("PRIMARY KEY"); 
    private String id; 

    private  ConstraintType(String id) {        
        this.id = id;
    }

    public String toString() {        
        return id;
    }

    public static ConstraintType getInstance(String id) {        
        if      ( id.compareToIgnoreCase("UNIQUE"     ) == 0 ) { return UNIQUE; }
        else if ( id.compareToIgnoreCase("FOREIGN KEY") == 0 ) { return FOREIGN_KEY; }
        else if ( id.compareToIgnoreCase("PRIMARY KEY") == 0 ) { return PRIMARY_KEY; }
        return null;
    }

 }